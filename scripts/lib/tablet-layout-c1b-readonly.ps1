#Requires -Version 7.5
# T-L1 C1b host-side mechanical read-only proof helpers. This file parses source; it never loads a runner.

Set-StrictMode -Version 3.0

$script:TL1C1bReadonlyC1aCounts = [ordered]@{
    fingerprint = 2L; boot_id = 2L; install = 1L; package_path = 2L; package_dump = 2L
}
$script:TL1C1bReadonlyC1bCounts = [ordered]@{
    content_t0 = 1L; content_status = 3L; content_c1 = 1L; content_c2 = 1L
    content_result = 1L; content_abort = 1L
}
$script:TL1C1bReadonlyT0Mappings = [ordered]@{
    prop_brand = [string[]]@('shell','getprop','ro.product.brand')
    prop_manufacturer = [string[]]@('shell','getprop','ro.product.manufacturer')
    prop_model = [string[]]@('shell','getprop','ro.product.model')
    prop_product = [string[]]@('shell','getprop','ro.product.name')
    prop_device = [string[]]@('shell','getprop','ro.product.device')
    prop_android_release = [string[]]@('shell','getprop','ro.build.version.release')
    prop_api = [string[]]@('shell','getprop','ro.build.version.sdk')
    prop_abi = [string[]]@('shell','getprop','ro.product.cpu.abilist')
    prop_fingerprint = [string[]]@('shell','getprop','ro.build.fingerprint')
    wm_size = [string[]]@('shell','wm','size')
    wm_density = [string[]]@('shell','wm','density')
    activity = [string[]]@('shell','dumpsys','activity','activities')
    window = [string[]]@('shell','dumpsys','window','windows')
    display = [string[]]@('shell','dumpsys','display')
    power = [string[]]@('shell','dumpsys','power')
    policy = [string[]]@('shell','dumpsys','window','policy')
    zen = [string[]]@('shell','settings','get','global','zen_mode')
    default_ime = [string[]]@('shell','settings','get','secure','default_input_method')
    input_method = [string[]]@('shell','dumpsys','input_method')
    am_config = [string[]]@('shell','am','get-config')
}
$script:TL1C1bReadonlyT0RunnerCounts = [ordered]@{
    devices = 1L; prop_brand = 1L; prop_manufacturer = 1L; prop_model = 1L
    prop_product = 1L; prop_device = 1L; prop_android_release = 1L; prop_api = 1L
    prop_abi = 1L; prop_fingerprint = 1L; wm_size = 2L; wm_density = 2L
    activity = 2L; window = 2L; display = 2L; power = 2L; policy = 2L
    zen = 2L; default_ime = 1L; input_method = 2L; am_config = 2L
}
$script:TL1C1bReadonlyZeroNames = [string[]]@(
    'display_screenshot_call_count','window_screenshot_call_count','ocr_invocation_count',
    'action_call_count','gesture_call_count','input_call_count','settings_mutation_count',
    'target_app_start_count','mcp_call_count','dispatch_call_count'
)

function Read-TL1C1bReadonlyAst {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Label)
    if (-not [IO.Path]::IsPathFullyQualified($Path)) { throw "$Label path 必须是绝对路径。" }
    $full = [IO.Path]::GetFullPath($Path)
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        -not [string]::IsNullOrWhiteSpace([string]$item.LinkType)) { throw "$Label 必须是 ordinary file。" }
    $bytes = [IO.File]::ReadAllBytes($full)
    try {
        if ($bytes.Length -notin 1..1048576) { throw "$Label byte count 越界。" }
        $source = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        if ($source.Length -gt 0 -and $source[0] -eq [char]0xfeff) { $source = $source.Substring(1) }
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($source, $full, [ref]$tokens, [ref]$errors)
        if ($errors.Count -ne 0) {
            $first = $errors[0]
            throw "$Label PowerShell parse error at $($first.Extent.StartLineNumber):$($first.Extent.StartColumnNumber)。"
        }
        $sha = 'sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        return [pscustomobject][ordered]@{ Path=$full; Source=$source; Ast=$ast; Sha256=$sha }
    }
    finally { if ($bytes.Length -ne 0) { [Array]::Clear($bytes, 0, $bytes.Length) } }
}

function Get-TL1C1bReadonlyAncestor {
    param([Parameter(Mandatory)]$Node, [Parameter(Mandatory)][type]$Type)
    $current = $Node.Parent
    while ($null -ne $current) {
        if ($current -is $Type) { return $current }
        $current = $current.Parent
    }
    return $null
}

function Get-TL1C1bReadonlyNamedArgumentAst {
    param([Parameter(Mandatory)][Management.Automation.Language.CommandAst]$Command, [Parameter(Mandatory)][string]$Name)
    $elements = [object[]]@($Command.CommandElements)
    $matches = [Collections.Generic.List[int]]::new()
    for ($index=1; $index -lt $elements.Length; $index++) {
        if ($elements[$index] -is [Management.Automation.Language.CommandParameterAst] -and
            $elements[$index].ParameterName -ceq $Name) { $matches.Add($index) }
    }
    if ($matches.Count -ne 1) { throw "$($Command.GetCommandName()) 必须有且仅有一个 -$Name。" }
    $parameter = [Management.Automation.Language.CommandParameterAst]$elements[$matches[0]]
    if ($null -ne $parameter.Argument) { return $parameter.Argument }
    $valueIndex = $matches[0] + 1
    if ($valueIndex -ge $elements.Length -or $elements[$valueIndex] -is [Management.Automation.Language.CommandParameterAst]) {
        throw "$($Command.GetCommandName()) -$Name 缺少值。"
    }
    return $elements[$valueIndex]
}

function Assert-TL1C1bReadonlyBareSwitch {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.CommandAst]$Command,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Label
    )

    $elements=[object[]]@($Command.CommandElements)
    $indices=[Collections.Generic.List[int]]::new()
    for($index=1;$index-lt$elements.Length;$index++){
        if($elements[$index]-is[Management.Automation.Language.CommandParameterAst]-and
           $elements[$index].ParameterName-ceq$Name){$indices.Add($index)}
    }
    $hasSeparateValue=$indices.Count-eq1-and$indices[0]+1-lt$elements.Length-and
        $elements[$indices[0]+1]-isnot[Management.Automation.Language.CommandParameterAst]
    if($indices.Count-ne1-or$null-ne$elements[$indices[0]].Argument-or$hasSeparateValue){
        throw "$Label 必须使用 bare -$Name；不得省略或显式绑定 false。"
    }
}

function Assert-TL1C1bReadonlyExactParameterNames {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.CommandAst]$Command,
        [Parameter(Mandatory)][string[]]$Expected,
        [Parameter(Mandatory)][string]$Label
    )

    $actual=[string[]]@($Command.CommandElements|Where-Object{
        $_-is[Management.Automation.Language.CommandParameterAst]
    }|ForEach-Object{$_.ParameterName})
    Assert-TL1C1bReadonlySequence $actual $Expected "$Label parameter closure"
}

function Assert-TL1C1bReadonlyExactArgumentVector {
    param(
        [Parameter(Mandatory)]$Ast,
        [Parameter(Mandatory)][string[]]$Expected,
        [Parameter(Mandatory)][string]$Label
    )

    if($Ast-isnot[Management.Automation.Language.ArrayExpressionAst]-or
       $Ast.SubExpression.Statements.Count-ne1){
        throw "$Label 必须是 exact array expression。"
    }
    $pipeline=$Ast.SubExpression.Statements[0]
    if($pipeline-isnot[Management.Automation.Language.PipelineAst]-or
       $pipeline.PipelineElements.Count-ne1-or
       $pipeline.PipelineElements[0]-isnot[Management.Automation.Language.CommandExpressionAst]-or
       $pipeline.PipelineElements[0].Redirections.Count-ne0-or
       $pipeline.PipelineElements[0].Expression-isnot[Management.Automation.Language.ArrayLiteralAst]){
        throw "$Label array topology 漂移。"
    }
    $elements=[object[]]@($pipeline.PipelineElements[0].Expression.Elements)
    if($elements.Count-ne$Expected.Count){throw "$Label argument count 漂移。"}
    for($index=0;$index-lt$Expected.Count;$index++){
        $expectedToken=[string]$Expected[$index]
        $separator=$expectedToken.IndexOf(':',[StringComparison]::Ordinal)
        if($separator-le0){throw "$Label internal expected token 非 exact。"}
        $kind=$expectedToken.Substring(0,$separator)
        $value=$expectedToken.Substring($separator+1)
        $element=$elements[$index]
        if($kind-ceq'literal'){
            if($element-isnot[Management.Automation.Language.StringConstantExpressionAst]-or
               [string]$element.Value-cne$value){throw "$Label literal argument value/order 漂移。"}
        }elseif($kind-ceq'variable'){
            if($element-isnot[Management.Automation.Language.VariableExpressionAst]-or
               -not$element.VariablePath.IsUnqualified-or
               $element.VariablePath.UserPath-cne$value){throw "$Label variable argument value/order 漂移。"}
        }else{throw "$Label internal expected token kind 非 exact。"}
    }
}

function Get-TL1C1bReadonlyNameArgumentAst {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.CommandAst]$Command,
        [Parameter(Mandatory)][int]$Position
    )
    if (@($Command.CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] }).Count -ne 0) {
        return Get-TL1C1bReadonlyNamedArgumentAst $Command 'Name'
    }
    $elements = [object[]]@($Command.CommandElements)
    $index = 1 + $Position
    if ($index -ge $elements.Length) { throw "$($Command.GetCommandName()) 缺少 positional Name。" }
    return $elements[$index]
}

function Get-TL1C1bReadonlyStaticString {
    param([Parameter(Mandatory)]$Ast, [Parameter(Mandatory)][string]$Label)
    if ($Ast -isnot [Management.Automation.Language.StringConstantExpressionAst]) {
        throw "$Label 必须是 static string literal。"
    }
    return [string]$Ast.Value
}

function Get-TL1C1bReadonlyConstantString {
    param([Parameter(Mandatory)]$Ast)

    if($Ast-is[Management.Automation.Language.StringConstantExpressionAst]){
        return [pscustomobject]@{IsStatic=$true;Value=[string]$Ast.Value}
    }
    if($Ast-is[Management.Automation.Language.ExpandableStringExpressionAst]){
        if(@($Ast.NestedExpressions).Count-eq0){return [pscustomobject]@{IsStatic=$true;Value=[string]$Ast.Value}}
        return [pscustomobject]@{IsStatic=$false;Value=$null}
    }
    if($Ast-is[Management.Automation.Language.BinaryExpressionAst]-and
       $Ast.Operator-eq[Management.Automation.Language.TokenKind]::Plus){
        $left=Get-TL1C1bReadonlyConstantString $Ast.Left
        $right=Get-TL1C1bReadonlyConstantString $Ast.Right
        if($left.IsStatic-and$right.IsStatic){return [pscustomobject]@{IsStatic=$true;Value=([string]$left.Value+[string]$right.Value)}}
    }
    return [pscustomobject]@{IsStatic=$false;Value=$null}
}

function Assert-TL1C1bReadonlyNoForbiddenGradleStrings {
    param([Parameter(Mandatory)]$Ast)

    foreach($node in @($Ast.FindAll({param($candidate)
        $candidate-is[Management.Automation.Language.StringConstantExpressionAst]-or
        $candidate-is[Management.Automation.Language.ExpandableStringExpressionAst]-or
        $candidate-is[Management.Automation.Language.BinaryExpressionAst]
    },$true))){
        $constant=Get-TL1C1bReadonlyConstantString $node
        if(-not$constant.IsStatic){continue}
        $value=[string]$constant.Value
        if($value.IndexOf(':tablet-c1b-probe:clean',[StringComparison]::Ordinal)-ge0-or
           $value.IndexOf('org.gradle.wrapper.GradleWrapperMain',[StringComparison]::Ordinal)-ge0){
            throw 'C1b runner 禁止 Gradle clean/WrapperMain 执行面。'
        }
    }
}

function Get-TL1C1bReadonlyLiteralArray {
    param([Parameter(Mandatory)]$Root, [Parameter(Mandatory)][string]$Label)
    $arrays = @($Root.FindAll({param($node) $node -is [Management.Automation.Language.ArrayLiteralAst]}, $true))
    if ($arrays.Count -ne 1) { throw "$Label 必须有且仅有一个 static array literal。" }
    $values = [Collections.Generic.List[string]]::new()
    foreach ($element in $arrays[0].Elements) {
        if ($element -isnot [Management.Automation.Language.StringConstantExpressionAst]) {
            throw "$Label array element 必须全部是 static string literal。"
        }
        $values.Add([string]$element.Value)
    }
    return ,$values.ToArray()
}

function Assert-TL1C1bReadonlySequence {
    param([Parameter(Mandatory)][string[]]$Actual, [Parameter(Mandatory)][string[]]$Expected, [Parameter(Mandatory)][string]$Label)
    if ($Actual.Count -ne $Expected.Count) { throw "$Label count 漂移。" }
    for ($index=0; $index -lt $Expected.Count; $index++) {
        if ($Actual[$index] -cne $Expected[$index]) { throw "$Label value/order 漂移。" }
    }
}

function Get-TL1C1bReadonlyFunction {
    param([Parameter(Mandatory)]$Ast, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Label)
    $functions = @($Ast.FindAll({param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $Name
    }, $true))
    if ($functions.Count -ne 1) { throw "$Label function $Name 必须 exact one。" }
    return $functions[0]
}

function Assert-TL1C1bReadonlyAstHygiene {
    param(
        [Parameter(Mandatory)]$Ast,
        [Parameter(Mandatory)][string]$Label,
        [string[]]$AllowedDotSourceVariables = @(),
        [switch]$AllowClosedProcessStart
    )
    $allowedDot = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in $AllowedDotSourceVariables) { [void]$allowedDot.Add($name) }
    $forbidden = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @('Invoke-Expression','iex','Start-Process','saps','start','Invoke-Command','Set-Variable','New-Variable','Set-Alias','New-Alias')) {
        [void]$forbidden.Add($name)
    }
    foreach ($command in @($Ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst]}, $true))) {
        if ($command.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Ampersand) {
            throw "$Label 禁止 ampersand dynamic invocation。"
        }
        if ($command.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Dot) {
            $elements = [object[]]@($command.CommandElements)
            if ($elements.Length -ne 1 -or $elements[0] -isnot [Management.Automation.Language.VariableExpressionAst] -or
                -not $allowedDot.Contains($elements[0].VariablePath.UserPath)) { throw "$Label dot-source closure 漂移。" }
            continue
        }
        $name = $command.GetCommandName()
        if ([string]::IsNullOrWhiteSpace($name)) { throw "$Label 禁止 dynamic command name。" }
        if ($forbidden.Contains($name)) { throw "$Label 禁止 command $name。" }
        if ($name -match '(?i)(?:^|[\\/])adb(?:\.exe)?$') { throw "$Label 禁止直接 adb executable。" }
        if ($name -ceq 'Invoke-TL1C1aProcess') {
            $filePath = Get-TL1C1bReadonlyNamedArgumentAst $command 'FilePath'
            if (($filePath -is [Management.Automation.Language.VariableExpressionAst] -and $filePath.VariablePath.UserPath -ceq 'AdbPath') -or
                ($filePath -is [Management.Automation.Language.StringConstantExpressionAst] -and $filePath.Value -match '(?i)(?:^|[\\/])adb(?:\.exe)?$')) {
                throw "$Label 禁止绕过封闭 wrapper 直接执行 adb。"
            }
        }
        $category = switch -Regex ($name) {
            '(?i)(display.*screenshot|screencap)' { 'display_screenshot_call_count'; break }
            '(?i)window.*screenshot' { 'window_screenshot_call_count'; break }
            '(?i)(^|[-_])ocr($|[-_])' { 'ocr_invocation_count'; break }
            '(?i)(mobile[-_]?action|invoke-.*action|perform-.*action)' { 'action_call_count'; break }
            '(?i)(gesture|swipe|(^|-)tap($|-))' { 'gesture_call_count'; break }
            '(?i)(send-.*input|invoke-.*input|^input$)' { 'input_call_count'; break }
            '(?i)(set-.*setting|mutate-.*setting)' { 'settings_mutation_count'; break }
            '(?i)(start-.*target|launch-.*app)' { 'target_app_start_count'; break }
            '(?i)(^mcp__|invoke-.*mcp)' { 'mcp_call_count'; break }
            '(?i)(^dispatch(?:\.ps1)?$|invoke-.*dispatch)' { 'dispatch_call_count'; break }
            default { $null }
        }
        if ($null -ne $category) { throw "$Label prohibited category $category is nonzero。" }
    }
    $fileNameAssignments = @($Ast.FindAll({param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [Management.Automation.Language.MemberExpressionAst] -and
        $node.Left.Member -is [Management.Automation.Language.StringConstantExpressionAst] -and
        $node.Left.Member.Value -ceq 'FileName'
    }, $true))
    $startInvocations = @($Ast.FindAll({param($node)
        $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
        $node.Member -is [Management.Automation.Language.StringConstantExpressionAst] -and
        $node.Member.Value -ceq 'Start'
    }, $true))
    if (-not $AllowClosedProcessStart -and ($fileNameAssignments.Count -ne 0 -or $startInvocations.Count -ne 0)) {
        throw "$Label 禁止 ProcessStartInfo/.Start executable bypass。"
    }
    if (@($Ast.FindAll({param($node)
        $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
        $node.Member -is [Management.Automation.Language.StringConstantExpressionAst] -and
        $node.Member.Value -in @('Invoke','InvokeReturnAsIs','InvokeWithContext')
    }, $true)).Count -ne 0) { throw "$Label 禁止 scriptblock/reflection dynamic member invocation。" }
}

function Assert-TL1C1bReadonlyDotSourceBindings {
    param([Parameter(Mandatory)]$Ast, [Parameter(Mandatory)]$Bindings, [Parameter(Mandatory)][string]$Label)
    foreach ($entry in $Bindings.GetEnumerator()) {
        $assignments = @($Ast.FindAll({param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
            $node.Left.VariablePath.IsUnqualified -and $node.Left.VariablePath.UserPath -ceq $entry.Key
        }, $true))
        if ($assignments.Count -ne 1) { throw "$Label dot-source binding $($entry.Key) 必须 exact one。" }
        $commands = @($assignments[0].Right.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst]}, $true))
        if ($commands.Count -ne 1 -or $commands[0].GetCommandName() -cne 'Join-Path') {
            throw "$Label dot-source binding $($entry.Key) 必须由 Join-Path 生成。"
        }
        $elements = [object[]]@($commands[0].CommandElements)
        if ($elements.Length -ne 3 -or $elements[1] -isnot [Management.Automation.Language.VariableExpressionAst] -or
            -not $elements[1].VariablePath.IsUnqualified -or $elements[1].VariablePath.UserPath -cne 'PSScriptRoot' -or
            $elements[2] -isnot [Management.Automation.Language.StringConstantExpressionAst] -or
            $elements[2].Value -cne $entry.Value) { throw "$Label dot-source binding $($entry.Key) path 漂移。" }
        $uses = @($Ast.FindAll({param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
            $node.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Dot -and
            $node.CommandElements.Count -eq 1 -and
            $node.CommandElements[0] -is [Management.Automation.Language.VariableExpressionAst] -and
            $node.CommandElements[0].VariablePath.IsUnqualified -and
            $node.CommandElements[0].VariablePath.UserPath -ceq $entry.Key
        }, $true))
        if ($uses.Count -ne 1 -or $uses[0].Extent.StartOffset -le $assignments[0].Extent.EndOffset) {
            throw "$Label dot-source binding $($entry.Key) use/order 漂移。"
        }
    }
}

function Assert-TL1C1bReadonlyExpectedCounts {
    param([Parameter(Mandatory)]$Actual, [Parameter(Mandatory)]$Expected, [Parameter(Mandatory)][string]$Label)
    if ($Actual.Count -ne $Expected.Count) { throw "$Label name set 漂移。" }
    foreach ($entry in $Expected.GetEnumerator()) {
        if (-not $Actual.Contains($entry.Key) -or [long]$Actual[$entry.Key] -ne [long]$entry.Value) {
            throw "$Label invocation count 漂移：$($entry.Key)。"
        }
    }
}

function New-TL1C1bReadonlyZeroCounts {
    $result = [ordered]@{}
    foreach ($name in $script:TL1C1bReadonlyZeroNames) { $result[$name] = 0L }
    return [pscustomobject]$result
}

function Assert-TL1C1bRunnerReadOnlyAst {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunnerPath)
    $parsed = Read-TL1C1bReadonlyAst $RunnerPath 'C1b runner'
    Assert-TL1C1bReadonlyAstHygiene $parsed.Ast 'C1b runner' @(
        'NativePathValidator','C1aLibrary','Validator','Library','ReadOnlyLibrary',
        'ArtifactProofLibrary','Aapt2Library','BuildEnvironmentLibrary','AdbServerLibrary','DispatchLockLibrary')
    Assert-TL1C1bReadonlyDotSourceBindings $parsed.Ast ([ordered]@{
        NativePathValidator='lib\tablet-layout-observation-v2-validator.ps1'
        C1aLibrary='lib\tablet-layout-c1a.ps1'
        Validator='lib\tablet-layout-observation-c1b-v1-validator.ps1'
        Library='lib\tablet-layout-c1b.ps1'
        ReadOnlyLibrary='lib\tablet-layout-c1b-readonly.ps1'
        ArtifactProofLibrary='lib\tablet-layout-c1b-artifact-proof.ps1'
        Aapt2Library='lib\tablet-layout-c1b-aapt2.ps1'
        BuildEnvironmentLibrary='lib\tablet-layout-c1b-build-env.ps1'
        AdbServerLibrary='lib\tablet-layout-c1b-adb-server.ps1'
        DispatchLockLibrary='lib\dispatch-lock.ps1'
    }) 'C1b runner'
    $launcherAssignments=@($parsed.Ast.FindAll({param($node)
        $node-is[Management.Automation.Language.AssignmentStatementAst]-and
        $node.Left.Extent.Text-cmatch'^\$(?:Java|gradleInvocation|signerInvocation|signerArguments|gradleArguments|pwsh)(?:$|\.|\[)'
    },$true))
    $expectedLauncherAssignments=[string[]]@(
        '$Java=$null',
        '$signerArguments=$null',
        '$gradleInvocation=Get-TL1C1bBuildEnvironmentGradleInvocation$buildEnvironmentGuard',
        '$signerInvocation=Get-TL1C1bBuildEnvironmentApkSignerInvocation$buildEnvironmentGuard',
        '$Java=[string]$gradleInvocation.FilePath',
        '$signerArguments=[string[]]@($signerInvocation.Arguments)',
        '$pwsh=(Get-Process-Id$PID).Path',
        @'
$gradleArguments=[string[]]@(@($gradleInvocation.Arguments)+@(Get-TL1C1bBuildEnvironmentGradleArguments$buildEnvironmentGuard)+@('-p',(Join-Path$RepoRoot'app'),':tablet-c1b-probe:verifyTabletC1bReadOnlyArtifact','--dependency-verification=strict','--no-build-cache','--no-configuration-cache','--rerun-tasks','--no-daemon','--console=plain','--quiet'))
'@
    )
    $expectedLauncherAssignments=[string[]]@($expectedLauncherAssignments|ForEach-Object{
        $_-replace'\s+',''
    })
    $expectedLauncherAssignmentSet=[Collections.Generic.HashSet[string]]::new(
        $expectedLauncherAssignments,[StringComparer]::Ordinal)
    $seenLauncherAssignments=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($assignment in $launcherAssignments){
        $compact=$assignment.Extent.Text-replace'\s+',''
        if(-not$expectedLauncherAssignmentSet.Contains($compact)-or-not$seenLauncherAssignments.Add($compact)){
            throw 'C1b runner held launcher assignment closure 漂移。'
        }
    }
    if($seenLauncherAssignments.Count-ne$expectedLauncherAssignmentSet.Count){
        throw 'C1b runner held launcher assignment closure 不完整。'
    }
    $javaEqualityGuards=@($parsed.Ast.FindAll({param($node)
        $node-is[Management.Automation.Language.IfStatementAst]-and
        (($node.Extent.Text-replace'\s+','')-ceq
            "if(`$Java-cne[string]`$signerInvocation.FilePath){throw'C1bGradle/apksigner未绑定同一heldJava。'}")
    },$true))
    if($javaEqualityGuards.Count-ne1){
        throw 'C1b runner Gradle/apksigner held Java equality guard 漂移。'
    }

    $genericProcesses = @($parsed.Ast.FindAll({param($node)
        $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Invoke-TL1C1aProcess'
    }, $true))
    $expectedGenericProcesses=[ordered]@{
        'fresh C1b dedicated read-only APK 构建与闭包证明'=[pscustomobject]@{
            FilePath='Java';Environment='buildEnvironment';Arguments='$gradleArguments';Timeout=300
        }
        'C1b debug APK signer 证书复核'=[pscustomobject]@{
            FilePath='Java';Environment='buildEnvironment';Arguments="([string[]]@(`$signerArguments+@('verify','--print-certs',`$Apk)))";Timeout=60
        }
        'C1b archived debug APK signer 证书复核'=[pscustomobject]@{
            FilePath='Java';Environment='buildEnvironment';Arguments="([string[]]@(`$signerArguments+@('verify','--print-certs',`$archivedDebugApkPath)))";Timeout=60
        }
    }
    $seenGenericProcesses=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($call in $genericProcesses) {
        Assert-TL1C1bReadonlyExactParameterNames $call `
            ([string[]]@('FilePath','Arguments','Operation','Environment','ClearEnvironment','TimeoutSec')) `
            'C1b runner held launcher'
        Assert-TL1C1bReadonlyBareSwitch $call 'ClearEnvironment' 'C1b runner held launcher'
        $operation=Get-TL1C1bReadonlyStaticString `
            (Get-TL1C1bReadonlyNamedArgumentAst $call 'Operation') 'C1b runner held launcher operation'
        if(-not$expectedGenericProcesses.Contains($operation)-or-not$seenGenericProcesses.Add($operation)){
            throw 'C1b runner held launcher operation closure 漂移。'
        }
        $expected=$expectedGenericProcesses[$operation]
        $filePath=Get-TL1C1bReadonlyNamedArgumentAst $call 'FilePath'
        $environment=Get-TL1C1bReadonlyNamedArgumentAst $call 'Environment'
        $arguments=Get-TL1C1bReadonlyNamedArgumentAst $call 'Arguments'
        $timeout=Get-TL1C1bReadonlyNamedArgumentAst $call 'TimeoutSec'
        if($filePath-isnot[Management.Automation.Language.VariableExpressionAst]-or
           -not$filePath.VariablePath.IsUnqualified-or$filePath.VariablePath.UserPath-cne$expected.FilePath-or
           $environment-isnot[Management.Automation.Language.VariableExpressionAst]-or
           -not$environment.VariablePath.IsUnqualified-or$environment.VariablePath.UserPath-cne$expected.Environment-or
           $arguments.Extent.Text-cne$expected.Arguments-or
           $timeout-isnot[Management.Automation.Language.ConstantExpressionAst]-or
           [int]$timeout.Value-ne[int]$expected.Timeout){
            throw "C1b runner held launcher binding 漂移：$operation。"
        }
    }
    if($genericProcesses.Count-ne3-or$seenGenericProcesses.Count-ne$expectedGenericProcesses.Count){
        throw 'C1b runner generic process invocation count 漂移。'
    }

    $guardedT0Calls=@($parsed.Ast.FindAll({param($node)
        $node-is[Management.Automation.Language.CommandAst]-and
        $node.GetCommandName()-ceq'Invoke-TL1C1bPrivateAdbGuardedProcess'
    },$true))
    if($guardedT0Calls.Count-ne1){
        throw 'C1b runner private adb guarded T0 launcher 必须 exact one。'
    }
    $guardedT0=$guardedT0Calls[0]
    Assert-TL1C1bReadonlyExactParameterNames $guardedT0 `
        ([string[]]@('Guard','FilePath','Arguments','Operation','ProcessEnvironment','ClearEnvironment','TimeoutSec','ClientKind')) `
        'C1b runner private adb guarded T0 launcher'
    if($guardedT0.CommandElements.Count-ne16){
        throw 'C1b runner private adb guarded T0 launcher argument count 漂移。'
    }
    Assert-TL1C1bReadonlyBareSwitch $guardedT0 'ClearEnvironment' 'C1b runner private adb guarded T0 launcher'
    $guardedT0Guard=Get-TL1C1bReadonlyNamedArgumentAst $guardedT0 'Guard'
    $guardedT0FilePath=Get-TL1C1bReadonlyNamedArgumentAst $guardedT0 'FilePath'
    $guardedT0Arguments=Get-TL1C1bReadonlyNamedArgumentAst $guardedT0 'Arguments'
    $guardedT0Operation=Get-TL1C1bReadonlyNamedArgumentAst $guardedT0 'Operation'
    $guardedT0Environment=Get-TL1C1bReadonlyNamedArgumentAst $guardedT0 'ProcessEnvironment'
    $guardedT0Timeout=Get-TL1C1bReadonlyNamedArgumentAst $guardedT0 'TimeoutSec'
    $guardedT0ClientKind=Get-TL1C1bReadonlyNamedArgumentAst $guardedT0 'ClientKind'
    Assert-TL1C1bReadonlyExactArgumentVector $guardedT0Arguments ([string[]]@(
        'literal:-NoProfile','literal:-File','variable:T0Runner','literal:-AdbPath',
        'variable:T0AdbCmd','literal:-RunId','variable:runId'
    )) 'C1b runner private adb guarded T0 Arguments'
    if($guardedT0Guard-isnot[Management.Automation.Language.VariableExpressionAst]-or
       -not$guardedT0Guard.VariablePath.IsUnqualified-or$guardedT0Guard.VariablePath.UserPath-cne'adbServerGuard'-or
       $guardedT0FilePath-isnot[Management.Automation.Language.VariableExpressionAst]-or
       -not$guardedT0FilePath.VariablePath.IsUnqualified-or$guardedT0FilePath.VariablePath.UserPath-cne'pwsh'-or
       (Get-TL1C1bReadonlyStaticString $guardedT0Operation 'C1b runner guarded T0 operation')-cne'fresh T0-L v5'-or
       $guardedT0Environment-isnot[Management.Automation.Language.VariableExpressionAst]-or
       -not$guardedT0Environment.VariablePath.IsUnqualified-or$guardedT0Environment.VariablePath.UserPath-cne't0Environment'-or
       $guardedT0Timeout-isnot[Management.Automation.Language.ConstantExpressionAst]-or[int]$guardedT0Timeout.Value-ne180-or
       (Get-TL1C1bReadonlyStaticString $guardedT0ClientKind 'C1b runner guarded T0 client kind')-cne'T0Root'){
        throw 'C1b runner private adb guarded T0 launcher binding 漂移。'
    }
    $firstGenericOffset=[long](($genericProcesses|ForEach-Object{
        $_.Extent.StartOffset
    }|Measure-Object -Minimum).Minimum)
    $javaSourceAssignment=@($launcherAssignments|Where-Object{
        ($_.Extent.Text-replace'\s+','')-ceq'$Java=[string]$gradleInvocation.FilePath'
    })
    if($javaSourceAssignment.Count-ne1-or
       $javaSourceAssignment[0].Extent.EndOffset-ge$javaEqualityGuards[0].Extent.StartOffset-or
       $javaEqualityGuards[0].Extent.EndOffset-ge$firstGenericOffset){
        throw 'C1b runner held Java source/equality ordering 漂移。'
    }
    foreach($commandName in @(
        'Invoke-TL1C1aAdb','Invoke-TL1C1bAdb','Get-TL1C1aSingleDevice',
        'Get-TL1C1aInstalledApkHostSha256','Wait-TL1C1aA11yReady'
    )){
        $calls=@($parsed.Ast.FindAll({param($node)
            $node-is[Management.Automation.Language.CommandAst]-and$node.GetCommandName()-ceq$commandName
        },$true))
        if($calls.Count-eq0){throw "C1b runner 缺少受控 ADB process surface：$commandName。"}
        foreach($call in $calls){
            Assert-TL1C1bReadonlyBareSwitch $call 'ClearEnvironment' "C1b runner $commandName"
            $environment=Get-TL1C1bReadonlyNamedArgumentAst $call 'ProcessEnvironment'
            if($environment-isnot[Management.Automation.Language.VariableExpressionAst]-or
               -not$environment.VariablePath.IsUnqualified-or
               $environment.VariablePath.UserPath-cne'adbEnvironment'){
                throw "C1b runner $commandName 必须绑定 exact `$adbEnvironment。"
            }
            $guard=Get-TL1C1bReadonlyNamedArgumentAst $call 'PrivateAdbServerGuard'
            if($guard-isnot[Management.Automation.Language.VariableExpressionAst]-or
               -not$guard.VariablePath.IsUnqualified-or
               $guard.VariablePath.UserPath-cne'adbServerGuard'){
                throw "C1b runner $commandName 必须绑定 exact -PrivateAdbServerGuard `$adbServerGuard。"
            }
        }
    }
    $adbTrustCalls=@($parsed.Ast.FindAll({param($node)
        $node-is[Management.Automation.Language.CommandAst]-and
        $node.GetCommandName()-ceq'Get-TL1C1bAdbTrustBinding'
    },$true))
    if($adbTrustCalls.Count-ne3){throw 'C1b runner adb trust invocation count 漂移。'}
    foreach($call in $adbTrustCalls){
        Assert-TL1C1bReadonlyBareSwitch $call 'ClearEnvironment' 'C1b runner Get-TL1C1bAdbTrustBinding'
        $environment=Get-TL1C1bReadonlyNamedArgumentAst $call 'ProcessEnvironment'
        $guardParameters=@($call.CommandElements|Where-Object{
            $_-is[Management.Automation.Language.CommandParameterAst]-and
            $_.ParameterName-ieq'PrivateAdbServerGuard'
        })
        if($environment-isnot[Management.Automation.Language.VariableExpressionAst]-or
           -not$environment.VariablePath.IsUnqualified-or
           $environment.VariablePath.UserPath-cne'adbTrustEnvironment'-or
           $guardParameters.Count-ne0){
            throw 'C1b runner adb trust version 必须保持非 private socket 普通 launcher 绑定。'
        }
    }
    $privateAdbExpected=[ordered]@{
        'Open-TL1C1bPrivateAdbServerGuard'=1
        'Assert-TL1C1bPrivateAdbServerGuardUnchanged'=2
        'Get-TL1C1bPrivateAdbClientEnvironment'=1
        'Close-TL1C1bPrivateAdbServerGuard'=2
        'Assert-C1bPrivateAdbServerFrozenState'=2
    }
    foreach($entry in $privateAdbExpected.GetEnumerator()){
        $calls=@($parsed.Ast.FindAll({param($node)
            $node-is[Management.Automation.Language.CommandAst]-and
            $node.GetCommandName()-ceq$entry.Key
        },$true))
        if($calls.Count-ne[int]$entry.Value){
            throw "C1b runner private adb lifecycle count 漂移：$($entry.Key)。"
        }
        foreach($call in $calls){
            if($entry.Key-ceq'Open-TL1C1bPrivateAdbServerGuard'){
                $adbPathArgument=Get-TL1C1bReadonlyNamedArgumentAst $call 'AdbPath'
                $environmentArgument=Get-TL1C1bReadonlyNamedArgumentAst $call 'ProcessEnvironment'
                if($adbPathArgument-isnot[Management.Automation.Language.VariableExpressionAst]-or
                   -not$adbPathArgument.VariablePath.IsUnqualified-or$adbPathArgument.VariablePath.UserPath-cne'AdbPath'-or
                   $environmentArgument-isnot[Management.Automation.Language.VariableExpressionAst]-or
                   -not$environmentArgument.VariablePath.IsUnqualified-or
                   $environmentArgument.VariablePath.UserPath-cne'adbTrustEnvironment'){
                    throw 'C1b runner private adb open binding 漂移。'
                }
            }elseif($entry.Key-cne'Assert-C1bPrivateAdbServerFrozenState'){
                $guardArgument=Get-TL1C1bReadonlyNameArgumentAst $call 0
                if($guardArgument-isnot[Management.Automation.Language.VariableExpressionAst]-or
                   -not$guardArgument.VariablePath.IsUnqualified-or
                   $guardArgument.VariablePath.UserPath-cne'adbServerGuard'){
                    throw "C1b runner private adb guard argument 漂移：$($entry.Key)。"
                }
            }
        }
    }
    $privateOpenIndex=$parsed.Source.IndexOf('$adbServerGuard=Open-TL1C1bPrivateAdbServerGuard',[StringComparison]::Ordinal)
    $privateClientIndex=$parsed.Source.IndexOf('$adbEnvironment=Get-TL1C1bPrivateAdbClientEnvironment',[StringComparison]::Ordinal)
    $firstDeviceIndex=$parsed.Source.IndexOf('$serial=Get-TL1C1aSingleDevice',[StringComparison]::Ordinal)
    $sessionConsumedIndex=$parsed.Source.IndexOf('$sessionConsumed=$true',[StringComparison]::Ordinal)
    $successCloseIndex=$parsed.Source.IndexOf('$adbServerCleanupBinding=Close-TL1C1bPrivateAdbServerGuard',[StringComparison]::Ordinal)
    $sidecarIndex=$parsed.Source.IndexOf('$sidecar=[ordered]@{',[StringComparison]::Ordinal)
    $finalCloseIndex=$parsed.Source.LastIndexOf('Close-TL1C1bPrivateAdbServerGuard $adbServerGuard',[StringComparison]::Ordinal)
    if($privateOpenIndex-lt0-or$privateClientIndex-le$privateOpenIndex-or
       $firstDeviceIndex-le$privateClientIndex-or$sessionConsumedIndex-le$firstDeviceIndex-or
       $successCloseIndex-le$sessionConsumedIndex-or$sidecarIndex-le$successCloseIndex-or
       $finalCloseIndex-le$sidecarIndex){
        throw 'C1b runner private adb open/use/cleanup/publish ordering 漂移。'
    }
    $implementationSnapshotCalls=@($parsed.Ast.FindAll({param($node)
        $node-is[Management.Automation.Language.CommandAst]-and
        $node.GetCommandName()-ceq'Assert-C1bImplementationSnapshot'
    },$true))
    $sidecarPublishIndex=$parsed.Source.IndexOf(
        'Write-TL1C1aBytesAtomic $RepoRoot $sidecarPath $pendingSidecarBytes',[StringComparison]::Ordinal)
    $postPublishImplementationIndex=$parsed.Source.LastIndexOf(
        'Assert-C1bImplementationSnapshot',[StringComparison]::Ordinal)
    if($implementationSnapshotCalls.Count-ne2-or$sidecarPublishIndex-lt0-or
       $postPublishImplementationIndex-le$sidecarPublishIndex){
        throw 'C1b runner implementation precheck/post-write snapshot lifecycle 漂移。'
    }
    $aapt2DumpCalls=@($parsed.Ast.FindAll({param($node)
        $node-is[Management.Automation.Language.CommandAst]-and
        $node.GetCommandName()-ceq'Get-TL1C1bPackagedAxmlDumpBinding'
    },$true))
    if($aapt2DumpCalls.Count-ne2){throw 'C1b runner packaged AXML dump invocation count 漂移。'}
    foreach($call in $aapt2DumpCalls){
        Assert-TL1C1bReadonlyBareSwitch $call 'ClearEnvironment' 'C1b runner aapt2 dump'
        $environment=Get-TL1C1bReadonlyNamedArgumentAst $call 'ProcessEnvironment'
        if($environment-isnot[Management.Automation.Language.VariableExpressionAst]-or
           -not$environment.VariablePath.IsUnqualified-or
           $environment.VariablePath.UserPath-cne'buildEnvironment'){
            throw 'C1b runner aapt2 dump 必须绑定 exact `$buildEnvironment。'
        }
    }
    foreach($forbiddenProcessHelper in @(
        'Find-TL1C1aApkSigner','Get-TL1C1aSignerDigest',
        'Get-TL1C1bBuildEnvironmentWrapperInvocation')){
        if(@($parsed.Ast.FindAll({param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -ceq $forbiddenProcessHelper
        },$true)).Count-ne0){throw "C1b runner 禁止 process helper：$forbiddenProcessHelper。"}
    }
    Assert-TL1C1bReadonlyNoForbiddenGradleStrings $parsed.Ast

    $c1aActual = [ordered]@{}
    $c1bActual = [ordered]@{}
    $readFunction = Get-TL1C1bReadonlyFunction $parsed.Ast 'Read-C1bControl' 'C1b runner'
    $readC1bCalls = @($readFunction.FindAll({param($node)
        $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Invoke-TL1C1bAdb'
    }, $true))
    if ($readC1bCalls.Count -ne 1) { throw 'Read-C1bControl wrapper 必须调用 exact one Invoke-TL1C1bAdb。' }
    $dynamicName = Get-TL1C1bReadonlyNameArgumentAst $readC1bCalls[0] 2
    if ($dynamicName -isnot [Management.Automation.Language.VariableExpressionAst] -or -not $dynamicName.VariablePath.IsUnqualified -or
        $dynamicName.VariablePath.UserPath -cne 'Name') { throw 'Read-C1bControl 必须仅转发 parameter $Name。' }
    if (@($readFunction.FindAll({param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
        $node.Left.VariablePath.UserPath -ceq 'Name'
    }, $true)).Count -ne 0) { throw 'Read-C1bControl 禁止改写 $Name。' }

    foreach ($call in @($parsed.Ast.FindAll({param($node)
        $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Invoke-TL1C1aAdb'
    }, $true))) {
        $name = Get-TL1C1bReadonlyStaticString (Get-TL1C1bReadonlyNameArgumentAst $call 2) 'Invoke-TL1C1aAdb -Name'
        if (-not $script:TL1C1bReadonlyC1aCounts.Contains($name)) { throw "C1b runner C1a Name 非 allowlist：$name。" }
        if (-not $c1aActual.Contains($name)) { $c1aActual[$name] = 0L }; $c1aActual[$name]++
    }
    foreach ($call in @($parsed.Ast.FindAll({param($node)
        $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Invoke-TL1C1bAdb'
    }, $true))) {
        $owner = Get-TL1C1bReadonlyAncestor $call ([Management.Automation.Language.FunctionDefinitionAst])
        if ($null -ne $owner -and $owner.Name -ceq 'Read-C1bControl') { continue }
        $name = Get-TL1C1bReadonlyStaticString (Get-TL1C1bReadonlyNameArgumentAst $call 2) 'Invoke-TL1C1bAdb -Name'
        if (-not $script:TL1C1bReadonlyC1bCounts.Contains($name)) { throw "C1b runner C1b Name 非 allowlist：$name。" }
        if (-not $c1bActual.Contains($name)) { $c1bActual[$name] = 0L }; $c1bActual[$name]++
    }
    foreach ($call in @($parsed.Ast.FindAll({param($node)
        $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Read-C1bControl'
    }, $true))) {
        $name = Get-TL1C1bReadonlyStaticString (Get-TL1C1bReadonlyNameArgumentAst $call 0) 'Read-C1bControl Name'
        if ($name -notin @('content_status','content_c1','content_c2','content_abort')) {
            throw "Read-C1bControl call-site closure 非 allowlist：$name。"
        }
        if (-not $c1bActual.Contains($name)) { $c1bActual[$name] = 0L }; $c1bActual[$name]++
    }
    Assert-TL1C1bReadonlyExpectedCounts $c1aActual $script:TL1C1bReadonlyC1aCounts 'C1b runner C1a'
    Assert-TL1C1bReadonlyExpectedCounts $c1bActual $script:TL1C1bReadonlyC1bCounts 'C1b runner C1b'
    return [pscustomobject][ordered]@{
        schema = 'tablet-layout-c1b-runner-readonly-ast/v1'
        runner_sha256 = $parsed.Sha256
        c1a_invocation_counts = [pscustomobject]$c1aActual
        c1b_invocation_counts = [pscustomobject]$c1bActual
        static_zero_counts = New-TL1C1bReadonlyZeroCounts
    }
}

function Get-TL1C1bReadonlyValidateSet {
    param([Parameter(Mandatory)]$Function, [Parameter(Mandatory)][string]$ParameterName, [Parameter(Mandatory)][string]$Label)
    $parameters = @($Function.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -ceq $ParameterName })
    if ($parameters.Count -ne 1) { throw "$Label parameter $ParameterName 必须 exact one。" }
    $sets = @($parameters[0].Attributes | Where-Object {
        $_ -is [Management.Automation.Language.AttributeAst] -and $_.TypeName.FullName -ceq 'ValidateSet'
    })
    if ($sets.Count -ne 1) { throw "$Label parameter $ParameterName 必须有 exact one ValidateSet。" }
    $values = [Collections.Generic.List[string]]::new()
    foreach ($argument in $sets[0].PositionalArguments) {
        if ($argument -isnot [Management.Automation.Language.StringConstantExpressionAst]) {
            throw "$Label ValidateSet 必须全部是 static string。"
        }
        $values.Add([string]$argument.Value)
    }
    return ,$values.ToArray()
}

function Assert-TL1C1bT0ReadOnlySurface {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunnerPath,
        [Parameter(Mandatory)][string]$LibraryPath
    )
    $runner = Read-TL1C1bReadonlyAst $RunnerPath 'T0 runner'
    $library = Read-TL1C1bReadonlyAst $LibraryPath 'T0 library'
    Assert-TL1C1bReadonlyAstHygiene $runner.Ast 'T0 runner' @('LibraryPath')
    Assert-TL1C1bReadonlyAstHygiene $library.Ast 'T0 library' -AllowClosedProcessStart
    Assert-TL1C1bReadonlyDotSourceBindings $runner.Ast ([ordered]@{LibraryPath='lib\tablet-intake.ps1'}) 'T0 runner'

    $mappingFunction = Get-TL1C1bReadonlyFunction $library.Ast 'Get-TabletAdbArguments' 'T0 library'
    $expectedNames = [string[]](@('devices') + @($script:TL1C1bReadonlyT0Mappings.Keys))
    $validateSet = Get-TL1C1bReadonlyValidateSet $mappingFunction 'Name' 'Get-TabletAdbArguments'
    Assert-TL1C1bReadonlySequence $validateSet $expectedNames 'Get-TabletAdbArguments ValidateSet'
    $statements = @($mappingFunction.Body.EndBlock.Statements)
    if ($statements.Count -ne 4 -or $statements[0] -isnot [Management.Automation.Language.IfStatementAst] -or
        $statements[1] -isnot [Management.Automation.Language.IfStatementAst] -or
        $statements[2] -isnot [Management.Automation.Language.AssignmentStatementAst] -or
        $statements[3] -isnot [Management.Automation.Language.ReturnStatementAst]) {
        throw 'Get-TabletAdbArguments control surface 漂移。'
    }
    $compact0 = $statements[0].Extent.Text -replace '\s',''
    $compact3 = $statements[3].Extent.Text -replace '\s',''
    if ($compact0 -cne "if(`$Name-eq'devices'){return[string[]]@('devices')}" -or
        $compact3 -cne "return[string[]](@('-s',`$Serial)+`$tail)") {
        throw 'Get-TabletAdbArguments devices/prefix surface 漂移。'
    }
    $serialCheckVariables = @($statements[1].FindAll({param($node)
        $node -is [Management.Automation.Language.VariableExpressionAst]
    }, $true) | ForEach-Object { $_.VariablePath.UserPath })
    if ($serialCheckVariables.Count -ne 1 -or $serialCheckVariables[0] -cne 'Serial' -or
        @($statements[1].FindAll({param($node) $node -is [Management.Automation.Language.ThrowStatementAst]}, $true)).Count -ne 1) {
        throw 'Get-TabletAdbArguments serial gate 漂移。'
    }
    if ($statements[2].Left -isnot [Management.Automation.Language.VariableExpressionAst] -or
        $statements[2].Left.VariablePath.UserPath -cne 'tail') { throw 'Get-TabletAdbArguments tail assignment 漂移。' }
    $switches = @($statements[2].FindAll({param($node) $node -is [Management.Automation.Language.SwitchStatementAst]}, $true))
    if ($switches.Count -ne 1 -or $switches[0].Condition.Extent.Text.Trim() -cne '$Name' -or
        $switches[0].Clauses.Count -ne $script:TL1C1bReadonlyT0Mappings.Count -or
        $null -eq $switches[0].Default -or
        @($switches[0].Default.FindAll({param($node) $node -is [Management.Automation.Language.ThrowStatementAst]}, $true)).Count -ne 1) {
        throw 'Get-TabletAdbArguments switch closure 漂移。'
    }
    $mappingActual = [ordered]@{}
    foreach ($clause in $switches[0].Clauses) {
        if ($clause.Item1 -isnot [Management.Automation.Language.StringConstantExpressionAst]) {
            throw 'Get-TabletAdbArguments switch name 必须是 static string。'
        }
        $name = [string]$clause.Item1.Value
        if (-not $script:TL1C1bReadonlyT0Mappings.Contains($name) -or $mappingActual.Contains($name)) {
            throw "Get-TabletAdbArguments switch name 漂移：$name。"
        }
        $arguments = Get-TL1C1bReadonlyLiteralArray $clause.Item2 "T0 mapping/$name"
        Assert-TL1C1bReadonlySequence $arguments $script:TL1C1bReadonlyT0Mappings[$name] "T0 mapping/$name"
        if ($arguments.Count -ge 2 -and $arguments[1] -ceq 'settings' -and
            ($arguments.Count -lt 3 -or $arguments[2] -cne 'get')) { throw "T0 mapping/$name settings 非 get。" }
        if ($arguments.Count -ge 2 -and $arguments[1] -ceq 'am' -and
            ($arguments.Count -ne 3 -or $arguments[2] -cne 'get-config')) { throw "T0 mapping/$name am 非 get-config。" }
        if ($arguments -contains 'screencap' -or $arguments -contains 'input' -or $arguments -contains 'monkey') {
            throw "T0 mapping/$name 含禁止设备命令。"
        }
        $mappingActual[$name] = [string[]]$arguments
    }

    $invokeFunction = Get-TL1C1bReadonlyFunction $library.Ast 'Invoke-TabletAdbQuery' 'T0 library'
    $mappingCalls = @($invokeFunction.FindAll({param($node)
        $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Get-TabletAdbArguments'
    }, $true))
    if ($mappingCalls.Count -ne 1) { throw 'Invoke-TabletAdbQuery 必须通过 exact one Get-TabletAdbArguments。' }
    $mappedName = Get-TL1C1bReadonlyNamedArgumentAst $mappingCalls[0] 'Name'
    $mappedSerial = Get-TL1C1bReadonlyNamedArgumentAst $mappingCalls[0] 'Serial'
    if ($mappedName -isnot [Management.Automation.Language.VariableExpressionAst] -or $mappedName.VariablePath.UserPath -cne 'Name' -or
        $mappedSerial -isnot [Management.Automation.Language.VariableExpressionAst] -or $mappedSerial.VariablePath.UserPath -cne 'Serial') {
        throw 'Invoke-TabletAdbQuery query binding 漂移。'
    }
    $argumentAssignments = @($invokeFunction.FindAll({param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
        $node.Left.VariablePath.IsUnqualified -and $node.Left.VariablePath.UserPath -ceq 'arguments'
    }, $true))
    $argumentIndexedOrMemberWrites = @($invokeFunction.FindAll({param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -match '^\$arguments(?:\[|\.)'
    }, $true))
    $argumentMemberCalls = @($invokeFunction.FindAll({param($node)
        $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
        $node.Expression.Extent.Text -match '^\$arguments(?:\[|\.|$)'
    }, $true))
    if ($argumentAssignments.Count -ne 1 -or $argumentAssignments[0].Operator -ne [Management.Automation.Language.TokenKind]::Equals -or
        $mappingCalls[0].Extent.StartOffset -lt $argumentAssignments[0].Extent.StartOffset -or
        $mappingCalls[0].Extent.EndOffset -gt $argumentAssignments[0].Extent.EndOffset -or
        $argumentIndexedOrMemberWrites.Count -ne 0 -or $argumentMemberCalls.Count -ne 0) {
        throw 'Invoke-TabletAdbQuery mapped arguments 可变面漂移。'
    }
    $argumentListCalls = @($invokeFunction.FindAll({param($node)
        $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
        $node.Expression.Extent.Text -ceq '$start.ArgumentList'
    }, $true))
    if ($argumentListCalls.Count -ne 1 -or $argumentListCalls[0].Member.Extent.Text -cne 'Add' -or
        $argumentListCalls[0].Arguments.Count -ne 1 -or
        $argumentListCalls[0].Arguments[0] -isnot [Management.Automation.Language.VariableExpressionAst] -or
        -not $argumentListCalls[0].Arguments[0].VariablePath.IsUnqualified -or
        $argumentListCalls[0].Arguments[0].VariablePath.UserPath -cne 'argument') {
        throw 'Invoke-TabletAdbQuery ArgumentList closure 漂移。'
    }
    $argumentLoop = Get-TL1C1bReadonlyAncestor $argumentListCalls[0] ([Management.Automation.Language.ForEachStatementAst])
    if ($null -eq $argumentLoop -or $argumentLoop.Variable.VariablePath.UserPath -cne 'argument' -or
        $argumentLoop.Condition.Extent.Text.Trim() -cne '$arguments') {
        throw 'Invoke-TabletAdbQuery ArgumentList foreach closure 漂移。'
    }
    if (@($invokeFunction.FindAll({param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -match '^\$start\.(?:Arguments|ArgumentList)'
    }, $true)).Count -ne 0) { throw 'Invoke-TabletAdbQuery 禁止绕过 ArgumentList closure。' }
    $fileAssignments = @($library.Ast.FindAll({param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [Management.Automation.Language.MemberExpressionAst] -and
        $node.Left.Member -is [Management.Automation.Language.StringConstantExpressionAst] -and
        $node.Left.Member.Value -ceq 'FileName'
    }, $true))
    $fileNameExpression = if ($fileAssignments.Count -eq 1 -and
        $fileAssignments[0].Right -is [Management.Automation.Language.CommandExpressionAst]) {
        $fileAssignments[0].Right.Expression
    } elseif ($fileAssignments.Count -eq 1) { $fileAssignments[0].Right } else { $null }
    if ($fileAssignments.Count -ne 1 -or (Get-TL1C1bReadonlyAncestor $fileAssignments[0] ([Management.Automation.Language.FunctionDefinitionAst])).Name -cne 'Invoke-TabletAdbQuery' -or
        $fileNameExpression -isnot [Management.Automation.Language.VariableExpressionAst] -or
        $fileNameExpression.VariablePath.UserPath -cne 'AdbPath') {
        throw 'T0 library executable choke point 漂移。'
    }
    $processStarts = @($library.Ast.FindAll({param($node)
        $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
        $node.Member -is [Management.Automation.Language.StringConstantExpressionAst] -and
        $node.Member.Value -ceq 'Start'
    }, $true))
    if ($processStarts.Count -ne 1 -or (Get-TL1C1bReadonlyAncestor $processStarts[0] ([Management.Automation.Language.FunctionDefinitionAst])).Name -cne 'Invoke-TabletAdbQuery' -or
        $processStarts[0].Expression.Extent.Text -cne '$process' -or $null -ne $processStarts[0].Arguments) {
        throw 'T0 library process Start choke point 漂移。'
    }

    $actualCalls = [ordered]@{}
    foreach ($call in @($runner.Ast.FindAll({param($node)
        $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Invoke-TabletAdbQuery'
    }, $true))) {
        $argument = Get-TL1C1bReadonlyNameArgumentAst $call 1
        if ($argument -is [Management.Automation.Language.StringConstantExpressionAst]) {
            $names = [string[]]@([string]$argument.Value)
        } elseif ($argument -is [Management.Automation.Language.VariableExpressionAst] -and $argument.VariablePath.UserPath -ceq 'name') {
            $loop = Get-TL1C1bReadonlyAncestor $call ([Management.Automation.Language.ForEachStatementAst])
            if ($null -eq $loop -or $loop.Variable.VariablePath.UserPath -cne 'name') {
                throw 'T0 runner dynamic query 未被 foreach closure 约束。'
            }
            $names = Get-TL1C1bReadonlyLiteralArray $loop.Condition 'T0 runner foreach query closure'
            Assert-TL1C1bReadonlySequence $names ([string[]]$script:TL1C1bReadonlyT0Mappings.Keys) 'T0 runner foreach query closure'
            if (@($loop.Body.FindAll({param($node)
                $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Invoke-TabletAdbQuery'
            }, $true)).Count -ne 1 -or @($loop.Body.FindAll({param($node)
                $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
                $node.Left.VariablePath.UserPath -ceq 'name'
            }, $true)).Count -ne 0) { throw 'T0 runner foreach query body 漂移。' }
        } else { throw 'T0 runner query Name 非 static/closed foreach。' }
        foreach ($name in $names) {
            if (-not $script:TL1C1bReadonlyT0RunnerCounts.Contains($name)) { throw "T0 runner query 非 allowlist：$name。" }
            if (-not $actualCalls.Contains($name)) { $actualCalls[$name] = 0L }; $actualCalls[$name]++
        }
    }
    Assert-TL1C1bReadonlyExpectedCounts $actualCalls $script:TL1C1bReadonlyT0RunnerCounts 'T0 runner'
    return [pscustomobject][ordered]@{
        schema = 'tablet-layout-c1b-t0-readonly-surface/v1'
        runner_sha256 = $runner.Sha256
        library_sha256 = $library.Sha256
        query_invocation_counts = [pscustomobject]$actualCalls
        mappings = [pscustomobject]$mappingActual
    }
}

function Get-TL1C1bReadonlyObjectMap {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string[]]$ExpectedNames, [Parameter(Mandatory)][string]$Label)
    $map = [ordered]@{}
    if ($Value -is [Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            if ($key -isnot [string] -or $map.Contains([string]$key)) { throw "$Label property name 非 exact。" }
            $map[[string]$key] = $Value[$key]
        }
    } elseif ($Value -is [pscustomobject]) {
        foreach ($property in $Value.PSObject.Properties) {
            if ($map.Contains($property.Name)) { throw "$Label duplicate property。" }
            $map[$property.Name] = $property.Value
        }
    } else { throw "$Label 必须是 object。" }
    if ($map.Count -ne $ExpectedNames.Count) { throw "$Label property count 非 exact。" }
    foreach ($name in $ExpectedNames) { if (-not $map.Contains($name)) { throw "$Label 缺少 exact property $name。" } }
    return $map
}

function Get-TL1C1bReadonlyInt64 {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$Label)
    if ($Value -isnot [long]) { throw "$Label 必须是 JSON integer/Int64。" }
    return [long]$Value
}

function ConvertTo-TL1C1bReadOnlyCounts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$CaptureTuple,
        [Parameter(Mandatory)]$ControlTuple,
        [Parameter(Mandatory)]$StaticProof
    )
    $captureNames = [string[]]@('c1_requests_accepted','c2_requests_accepted','result_read_count','recapture_count')
    $controlNames = [string[]]@('c1_requests_accepted','c2_requests_accepted','committed_tokens','recapture_count')
    $proofNames = [string[]]@('schema','runner_sha256','c1a_invocation_counts','c1b_invocation_counts','static_zero_counts')
    $capture = Get-TL1C1bReadonlyObjectMap $CaptureTuple $captureNames 'capture tuple'
    $control = Get-TL1C1bReadonlyObjectMap $ControlTuple $controlNames 'control tuple'
    $proof = Get-TL1C1bReadonlyObjectMap $StaticProof $proofNames 'static proof'
    if ($proof.schema -cne 'tablet-layout-c1b-runner-readonly-ast/v1' -or
        $proof.runner_sha256 -isnot [string] -or $proof.runner_sha256 -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw 'static proof identity 非 exact。'
    }
    foreach ($binding in @(
        [pscustomobject]@{Value=$proof.c1a_invocation_counts;Expected=$script:TL1C1bReadonlyC1aCounts;Label='proof.c1a_invocation_counts'},
        [pscustomobject]@{Value=$proof.c1b_invocation_counts;Expected=$script:TL1C1bReadonlyC1bCounts;Label='proof.c1b_invocation_counts'}
    )) {
        $map = Get-TL1C1bReadonlyObjectMap $binding.Value ([string[]]$binding.Expected.Keys) $binding.Label
        foreach ($entry in $binding.Expected.GetEnumerator()) {
            $value = Get-TL1C1bReadonlyInt64 $map[$entry.Key] "$($binding.Label).$($entry.Key)"
            if ($value -ne [long]$entry.Value) { throw "$($binding.Label).$($entry.Key) 非 exact。" }
        }
    }
    $c1Capture = Get-TL1C1bReadonlyInt64 $capture.c1_requests_accepted 'capture.c1_requests_accepted'
    $c2Capture = Get-TL1C1bReadonlyInt64 $capture.c2_requests_accepted 'capture.c2_requests_accepted'
    $resultReads = Get-TL1C1bReadonlyInt64 $capture.result_read_count 'capture.result_read_count'
    $recapture = Get-TL1C1bReadonlyInt64 $capture.recapture_count 'capture.recapture_count'
    $c1Control = Get-TL1C1bReadonlyInt64 $control.c1_requests_accepted 'control.c1_requests_accepted'
    $c2Control = Get-TL1C1bReadonlyInt64 $control.c2_requests_accepted 'control.c2_requests_accepted'
    $controlRecapture = Get-TL1C1bReadonlyInt64 $control.recapture_count 'control.recapture_count'
    if ($c1Capture -ne 1 -or $c2Capture -ne 1 -or $resultReads -ne 1 -or $recapture -ne 0 -or
        $c1Control -ne $c1Capture -or $c2Control -ne $c2Capture -or $controlRecapture -ne $recapture) {
        throw 'capture/control tuple value 非 C1b exact terminal tuple。'
    }
    if ($control.committed_tokens -isnot [Array]) { throw 'control.committed_tokens 必须是 exact array。' }
    $tokens = [object[]]@($control.committed_tokens)
    if ($tokens.Count -ne 2 -or $tokens[0] -isnot [string] -or $tokens[1] -isnot [string] -or
        $tokens[0] -cne 'c1' -or $tokens[1] -cne 'c2') { throw 'control.committed_tokens 非 exact c1/c2。' }
    $zeroMap = Get-TL1C1bReadonlyObjectMap $proof.static_zero_counts $script:TL1C1bReadonlyZeroNames 'static_zero_counts'
    $result = [ordered]@{ a11y_frame_capture_count = [long]($c1Capture + $c2Capture); recapture_count = $recapture }
    foreach ($name in $script:TL1C1bReadonlyZeroNames) {
        $value = Get-TL1C1bReadonlyInt64 $zeroMap[$name] "static_zero_counts.$name"
        if ($value -ne 0) { throw "static_zero_counts.$name 必须 exact zero。" }
        $result[$name] = 0L
    }
    return [pscustomobject]$result
}
