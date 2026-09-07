# r14 preflight 的可跟踪注入源；只定义函数，不启动冻结脚本或外部进程。
# 宿主 leaf 提供 Assert-Preflight、Assert-Identity、Assert-FinalPath、
# Open-DirectoryChain、Complete-PrePublicationLocalFailure 及既有 native identity 类型。

function Get-TL1C1bPreflightGitTreeSnapshot {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][ValidateRange(1, 20000)][int]$ExpectedFileCount,
        [Parameter(Mandatory)][ValidatePattern('\Asha256:[0-9a-f]{64}\z')]
        [string]$ExpectedCatalogSha256,
        [Parameter(Mandatory)][ValidateRange(1, 20000)][int]$ExpectedIdentityCount,
        [Parameter(Mandatory)][ValidateRange(0, 20000)]
        [int]$ExpectedInternalHardlinkGroupCount,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Stage
    )

    Assert-Preflight (
        [IO.Path]::IsPathFullyQualified($Root) -and
        $Root -cmatch '\A[A-Za-z]:\\' -and
        -not $Root.Substring(2).Contains(':')
    ) 'Git trust-tree root must be an absolute local DOS path.'
    $canonicalRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    # Acquisition already accounts for its own primary/cleanup failures.
    $rootChain = Open-DirectoryChain $canonicalRoot "Git trust-tree $Stage root"
    $directories = [Collections.Generic.List[object]]::new()
    $files = [Collections.Generic.List[object]]::new()
    $directoryQueue = [Collections.Generic.Queue[string]]::new()
    $seenPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $handle = $null
    $stream = $null
    $primaryFailure = $null
    $cleanupFailures = [Collections.Generic.List[System.Exception]]::new()
    $snapshot = $null
    try {
        $directoryQueue.Enqueue($canonicalRoot)
        [void]$seenPaths.Add($canonicalRoot)
        while ($directoryQueue.Count -ne 0) {
            $directoryPath = $directoryQueue.Dequeue()
            $handle = [TL1C1bPreparedNotAuthorizedFileIdentityV1]::
                OpenDirectoryDenyWriteDelete($directoryPath)
            $identity = [TL1C1bPreparedNotAuthorizedFileIdentityV1]::Read($handle)
            Assert-Identity $identity $true "Git trust-tree $Stage directory" $true
            Assert-FinalPath $handle $directoryPath "Git trust-tree $Stage directory"
            $children = [string[]]@([IO.Directory]::EnumerateFileSystemEntries($directoryPath))
            [Array]::Sort($children, [StringComparer]::Ordinal)
            $relativeDirectory = [IO.Path]::GetRelativePath($canonicalRoot, $directoryPath).Replace('\', '/')
            $directories.Add([pscustomobject]@{
                Path = $directoryPath
                RelativePath = $relativeDirectory
                Identity = $identity
                Handle = $handle
                Children = $children
            })
            $handle = $null
            Assert-Preflight ($directories.Count -le 20000) (
                'Git trust-tree directory count exceeds the closed bound.')

            foreach ($entryPath in $children) {
                $full = [IO.Path]::GetFullPath($entryPath)
                $relative = [IO.Path]::GetRelativePath($canonicalRoot, $full).Replace('\', '/')
                Assert-Preflight (
                    -not [string]::IsNullOrWhiteSpace($relative) -and
                    $relative -cnotmatch '[\r\n=:]' -and
                    -not [IO.Path]::IsPathFullyQualified($relative) -and
                    $relative -cnotmatch '(^|/)\.\.(/|$)' -and
                    $relative -cne '.' -and
                    $seenPaths.Add($full)
                ) 'Git trust-tree entry has an unsafe or duplicate catalog path.'
                $attributes = [IO.File]::GetAttributes($full)
                Assert-Preflight (
                    ($attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0
                ) 'Git trust-tree entry is a reparse point.'
                if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
                    $directoryQueue.Enqueue($full)
                    continue
                }
                Assert-Preflight ($files.Count -lt $ExpectedFileCount) (
                    'Git trust-tree has more files than the frozen count.')
                $handle = [TL1C1bPreparedNotAuthorizedFileIdentityV1]::
                    OpenFileReadNoFollowDenyWriteDelete($full)
                $identity = [TL1C1bPreparedNotAuthorizedFileIdentityV1]::Read($handle)
                Assert-Identity $identity $false "Git trust-tree $Stage file" $false
                Assert-FinalPath $handle $full "Git trust-tree $Stage file"
                $stream = [IO.FileStream]::new($handle, [IO.FileAccess]::Read, 65536, $false)
                $handle = $null
                Assert-Preflight ([uint64]$stream.Length -eq [uint64]$identity.FileSize) (
                    'Git trust-tree held file length differs from its native identity.')
                $sha = 'sha256:' + [Convert]::ToHexString(
                    [Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant()
                $files.Add([pscustomobject]@{
                    Path = $full
                    RelativePath = $relative
                    Identity = $identity
                    Sha256 = $sha
                    Stream = $stream
                })
                $stream = $null
            }
        }
        Assert-Preflight ($files.Count -eq $ExpectedFileCount) (
            'Git trust-tree file count differs from the frozen count.')

        $byPath = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        $groups = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        foreach ($entry in $files) {
            $byPath.Add([string]$entry.RelativePath, $entry)
            $identity = [TL1C1bPreparedNotAuthorizedFileIdentityV1]::Read($entry.Stream.SafeFileHandle)
            Assert-Identity $identity $false "Git trust-tree $Stage held file" $false
            Assert-FinalPath $entry.Stream.SafeFileHandle $entry.Path "Git trust-tree $Stage held file"
            Assert-Preflight (
                $identity.StableId -ceq $entry.Identity.StableId -and
                $identity.LinkCount -eq $entry.Identity.LinkCount -and
                $identity.FileSize -eq $entry.Identity.FileSize -and
                $identity.FileAttributes -eq $entry.Identity.FileAttributes -and
                $identity.LastWriteTimeUtcFileTime -eq $entry.Identity.LastWriteTimeUtcFileTime
            ) 'Git trust-tree held file identity changed during its snapshot.'
            $group = $null
            if (-not $groups.TryGetValue([string]$identity.StableId, [ref]$group)) {
                $group = [pscustomobject]@{ LinkCount = [uint32]$identity.LinkCount; PathCount = 0 }
                $groups.Add([string]$identity.StableId, $group)
            }
            Assert-Preflight ($group.LinkCount -eq $identity.LinkCount) (
                'Git trust-tree aliases disagree on their native link count.')
            $group.PathCount++
        }
        $hardlinkGroups = 0
        foreach ($group in $groups.Values) {
            Assert-Preflight ($group.PathCount -eq $group.LinkCount) (
                'Git trust-tree hardlinks must close entirely inside the frozen catalog.')
            if ($group.LinkCount -gt 1) { $hardlinkGroups++ }
        }
        Assert-Preflight (
            $groups.Count -eq $ExpectedIdentityCount -and
            $hardlinkGroups -eq $ExpectedInternalHardlinkGroupCount
        ) 'Git trust-tree identity or internal hardlink group count differs from the frozen value.'

        $paths = [string[]]@($byPath.Keys)
        [Array]::Sort($paths, [StringComparer]::Ordinal)
        $catalogLines = [Collections.Generic.List[string]]::new()
        $identityLines = [Collections.Generic.List[string]]::new()
        foreach ($relative in $paths) {
            $entry = $byPath[$relative]
            $catalogLines.Add("$relative=$($entry.Sha256)")
            $identity = $entry.Identity
            $identityLines.Add((
                '{0}={1}:{2}:{3}:{4}:{5}' -f $relative, $identity.StableId,
                    $identity.LinkCount, $identity.FileSize,
                    $identity.LastWriteTimeUtcFileTime, $identity.FileAttributes))
        }
        $catalogSha = 'sha256:' + [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData(
                [Text.UTF8Encoding]::new($false).GetBytes($catalogLines -join "`n"))).ToLowerInvariant()
        Assert-Preflight ($catalogSha -ceq $ExpectedCatalogSha256) (
            'Git trust-tree catalog SHA-256 differs from the frozen value.')
        $fileIdentitySha = 'sha256:' + [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData(
                [Text.UTF8Encoding]::new($false).GetBytes($identityLines -join "`n"))).ToLowerInvariant()

        $directoryIdentityLines = [Collections.Generic.List[string]]::new()
        foreach ($entry in $directories) {
            $identity = [TL1C1bPreparedNotAuthorizedFileIdentityV1]::Read($entry.Handle)
            Assert-Identity $identity $true "Git trust-tree $Stage held directory" $true
            Assert-FinalPath $entry.Handle $entry.Path "Git trust-tree $Stage held directory"
            Assert-Preflight ($identity.StableId -ceq $entry.Identity.StableId) (
                'Git trust-tree directory identity changed during its snapshot.')
            $currentChildren = [string[]]@([IO.Directory]::EnumerateFileSystemEntries($entry.Path))
            [Array]::Sort($currentChildren, [StringComparer]::Ordinal)
            Assert-Preflight ($currentChildren.Count -eq $entry.Children.Count) (
                'Git trust-tree directory membership changed during its snapshot.')
            for ($index = 0; $index -lt $currentChildren.Count; $index++) {
                Assert-Preflight ($currentChildren[$index] -ceq $entry.Children[$index]) (
                    'Git trust-tree directory membership changed during its snapshot.')
            }
            $directoryIdentityLines.Add("$($entry.RelativePath)=$($identity.StableId)")
        }
        $directoryLines = $directoryIdentityLines.ToArray()
        [Array]::Sort($directoryLines, [StringComparer]::Ordinal)
        $directoryIdentitySha = 'sha256:' + [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData(
                [Text.UTF8Encoding]::new($false).GetBytes($directoryLines -join "`n"))).ToLowerInvariant()
        $snapshot = [pscustomobject][ordered]@{
            Root = $canonicalRoot
            Stage = $Stage
            FileCount = [long]$files.Count
            CatalogSha256 = $catalogSha
            IdentityCount = [long]$groups.Count
            InternalHardlinkGroupCount = [long]$hardlinkGroups
            FileIdentityCatalogSha256 = $fileIdentitySha
            DirectoryIdentityCatalogSha256 = $directoryIdentitySha
            CleanupCompleted = $false
        }
    }
    catch { $primaryFailure = $_ }
    finally {
        if ($null -ne $stream) {
            try { $stream.Dispose() }
            catch { $cleanupFailures.Add($_.Exception) }
        }
        if ($null -ne $handle) {
            try { $handle.Dispose() }
            catch { $cleanupFailures.Add($_.Exception) }
        }
        for ($index = $files.Count - 1; $index -ge 0; $index--) {
            try { $files[$index].Stream.Dispose() }
            catch { $cleanupFailures.Add($_.Exception) }
        }
        for ($index = $directories.Count - 1; $index -ge 0; $index--) {
            try { $directories[$index].Handle.Dispose() }
            catch { $cleanupFailures.Add($_.Exception) }
        }
        for ($index = $rootChain.Entries.Count - 1; $index -ge 0; $index--) {
            try { $rootChain.Entries[$index].Handle.Dispose() }
            catch { $cleanupFailures.Add($_.Exception) }
        }
    }
    Complete-PrePublicationLocalFailure "Git trust-tree $Stage snapshot" $primaryFailure (
        [System.Exception[]]$cleanupFailures.ToArray())
    $snapshot.CleanupCompleted = $true
    return $snapshot
}

function Assert-TL1C1bPreflightGitTreeContinuity {
    param(
        [Parameter(Mandatory)][object]$Before,
        [Parameter(Mandatory)][object]$After
    )
    Assert-Preflight (
        $Before.CleanupCompleted -and $After.CleanupCompleted -and
        $Before.Root -ceq $After.Root -and
        $Before.FileCount -eq $After.FileCount -and
        $Before.CatalogSha256 -ceq $After.CatalogSha256 -and
        $Before.IdentityCount -eq $After.IdentityCount -and
        $Before.InternalHardlinkGroupCount -eq $After.InternalHardlinkGroupCount -and
        $Before.FileIdentityCatalogSha256 -ceq $After.FileIdentityCatalogSha256 -and
        $Before.DirectoryIdentityCatalogSha256 -ceq $After.DirectoryIdentityCatalogSha256
    ) 'Git trust-tree pre/post content, identity, topology, or cleanup continuity drifted.'
}

function Assert-TL1C1bPreflightLauncherByteReturn {
    param([Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$LauncherAst)

    $functions = @($LauncherAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'Read-LauncherHeldFileBytes'
    }, $true))
    Assert-Preflight ($functions.Count -eq 1) (
        'Launcher held-byte function must be unique for the unary-comma contract.')
    $returns = @($functions[0].Body.FindAll({
        param($node)
        $node -is [Management.Automation.Language.ReturnStatementAst]
    }, $true))
    Assert-Preflight ($returns.Count -eq 1) (
        'Launcher held-byte function must have exactly one return statement.')
    $pipeline = $returns[0].Pipeline
    Assert-Preflight (
        $null -ne $pipeline -and $pipeline.PipelineElements.Count -eq 1 -and
        $pipeline.PipelineElements[0] -is [Management.Automation.Language.CommandExpressionAst] -and
        $pipeline.PipelineElements[0].Redirections.Count -eq 0 -and
        $pipeline.PipelineElements[0].Expression -is [Management.Automation.Language.ArrayLiteralAst]
    ) 'Launcher held-byte return must be a single unary-comma expression.'
    $expression = $pipeline.PipelineElements[0].Expression
    Assert-Preflight (
        $expression.Elements.Count -eq 1 -and
        $expression.Elements[0] -is [Management.Automation.Language.VariableExpressionAst] -and
        $expression.Elements[0].VariablePath.UserPath -ceq 'bytes' -and
        -not $expression.Elements[0].Splatted -and
        $returns[0].Extent.Text -cmatch '\Areturn\s+,\s*\$bytes\z'
    ) 'Launcher held-byte return must be exactly return ,$bytes.'

    $runspace = $null
    $pipelineEngine = $null
    $primaryFailure = $null
    $cleanupFailures = [Collections.Generic.List[System.Exception]]::new()
    $cases = [Collections.Generic.List[object]]::new()
    try {
        # Only the already exact-validated return expression enters this empty
        # runspace. No launcher function/body, module, file or child process runs.
        $initialState = [Management.Automation.Runspaces.InitialSessionState]::Create()
        $initialState.LanguageMode = [Management.Automation.PSLanguageMode]::FullLanguage
        $runspace = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($initialState)
        $runspace.Open()
        foreach ($length in [int[]]@(0, 1, 5)) {
            $payload = [byte[]]::new($length)
            for ($index = 0; $index -lt $length; $index++) {
                $payload[$index] = [byte](($index * 71 + 129) % 256)
            }
            $pipelineEngine = [Management.Automation.PowerShell]::Create()
            $pipelineEngine.Runspace = $runspace
            [void]$pipelineEngine.AddScript(
                'param([byte[]]$bytes) ' + $returns[0].Extent.Text, $true)
            [void]$pipelineEngine.AddArgument($payload)
            $result = $pipelineEngine.Invoke()
            Assert-Preflight (
                -not $pipelineEngine.HadErrors -and
                $pipelineEngine.Streams.Error.Count -eq 0 -and
                $result.Count -eq 1 -and
                $result[0].PSObject.BaseObject.GetType() -eq [byte[]] -and
                $result[0].PSObject.BaseObject.Length -eq $length
            ) "Launcher unary-comma runtime canary lost byte-array shape at length $length."
            Assert-Preflight (
                [Convert]::ToBase64String([byte[]]$result[0].PSObject.BaseObject) -ceq
                [Convert]::ToBase64String($payload)
            ) "Launcher unary-comma runtime canary changed content at length $length."
            $cases.Add([pscustomobject][ordered]@{
                byte_length = [long]$length
                pipeline_object_count = [long]$result.Count
                exact_byte_array_type = $true
                content_matches = $true
            })
            try {
                $pipelineEngine.Dispose()
                $pipelineEngine = $null
            }
            catch {
                $cleanupFailures.Add($_.Exception)
                break
            }
        }
    }
    catch { $primaryFailure = $_ }
    finally {
        if ($null -ne $pipelineEngine) {
            try { $pipelineEngine.Dispose() }
            catch { $cleanupFailures.Add($_.Exception) }
        }
        if ($null -ne $runspace) {
            try { $runspace.Dispose() }
            catch { $cleanupFailures.Add($_.Exception) }
        }
    }
    Complete-PrePublicationLocalFailure 'Launcher unary-comma runtime canary' $primaryFailure (
        [System.Exception[]]$cleanupFailures.ToArray())
    return [pscustomobject][ordered]@{
        function_name = 'Read-LauncherHeldFileBytes'
        exact_unary_comma_return_verified = $true
        isolated_return_expression_only = $true
        launcher_function_invocation_count = 0L
        case_count = [long]$cases.Count
        cases = [object[]]$cases.ToArray()
        cleanup_completed = $true
    }
}

function Assert-TL1C1bPreflightLauncherStreamContract {
    param([Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$LauncherAst)

    # Token text preserves whitespace inside quoted literals. Only lexical
    # whitespace/comments are ignored; no launcher expression is evaluated.
    $compact = {
        param([Management.Automation.Language.Ast]$Node)
        $tokens = $null
        $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseInput(
            $Node.Extent.Text, [ref]$tokens, [ref]$errors)
        Assert-Preflight ($errors.Count -eq 0) 'Launcher stream-contract fragment did not parse.'
        return [string]::Join('', [string[]]@($tokens | Where-Object {
            $_.Kind -notin @('EndOfInput', 'NewLine', 'LineContinuation', 'Comment')
        } | ForEach-Object { $_.Text }))
    }
    $unwrap = {
        param([Management.Automation.Language.Ast]$Node)
        while ($true) {
            if ($Node -is [Management.Automation.Language.CommandExpressionAst]) {
                Assert-Preflight ($Node.Redirections.Count -eq 0) 'Launcher stream-contract expression redirects a stream.'
                $Node = $Node.Expression
            } elseif ($Node -is [Management.Automation.Language.ConvertExpressionAst]) {
                Assert-Preflight ($Node.Type.TypeName.FullName -in @('pscustomobject', 'ordered')) (
                    'Launcher stream-contract expression has an unexpected cast.')
                $Node = $Node.Child
            } elseif ($Node -is [Management.Automation.Language.PipelineAst]) {
                Assert-Preflight ($Node.PipelineElements.Count -eq 1) 'Launcher stream-contract expression has a pipeline.'
                $Node = $Node.PipelineElements[0]
            } elseif ($Node -is [Management.Automation.Language.StatementBlockAst]) {
                Assert-Preflight ($Node.Statements.Count -eq 1) 'Launcher stream-contract expression has multiple statements.'
                $Node = $Node.Statements[0]
            } else { return $Node }
        }
    }
    $assignments = @($LauncherAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst]
    }, $true))
    $bootstrapAssignments = @($assignments | Where-Object {
        $_.Left -is [Management.Automation.Language.VariableExpressionAst] -and
        ($_.Left.VariablePath.UserPath -split ':')[-1] -ieq 'childBootstrapSource'
    })
    Assert-Preflight (
        $bootstrapAssignments.Count -eq 1 -and
        $bootstrapAssignments[0].Left.VariablePath.UserPath -ceq 'childBootstrapSource' -and
        $bootstrapAssignments[0].Operator -eq [Management.Automation.Language.TokenKind]::Equals
    ) 'Launcher stream contract requires one literal childBootstrapSource assignment.'
    $bootstrapLiteral = & $unwrap $bootstrapAssignments[0].Right
    Assert-Preflight ($bootstrapLiteral -is [Management.Automation.Language.StringConstantExpressionAst]) (
        'Launcher stream contract requires a literal bootstrap, without interpolation.')
    $tokens = $null
    $errors = $null
    $bootstrapAst = [Management.Automation.Language.Parser]::ParseInput(
        $bootstrapLiteral.Value, [ref]$tokens, [ref]$errors)
    Assert-Preflight (
        $errors.Count -eq 0 -and $null -eq $bootstrapAst.ParamBlock -and
        $null -eq $bootstrapAst.BeginBlock -and $null -eq $bootstrapAst.ProcessBlock -and
        $null -eq $bootstrapAst.DynamicParamBlock -and $null -ne $bootstrapAst.EndBlock -and
        $bootstrapAst.EndBlock.Statements.Count -ge 2
    ) 'Launcher stream contract requires a plain bootstrap statement sequence.'
    Assert-Preflight (
        (& $compact $bootstrapAst.EndBlock.Statements[0]) -ceq '$ProgressPreference=''SilentlyContinue''' -and
        (& $compact $bootstrapAst.EndBlock.Statements[1]) -ceq '$ErrorActionPreference=''Stop'''
    ) 'Launcher stream contract must suppress progress first and retain ErrorActionPreference Stop second.'
    $bootstrapWrites = @($bootstrapAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst]
    }, $true))
    Assert-Preflight (@($bootstrapWrites | Where-Object {
        $_.Left -isnot [Management.Automation.Language.VariableExpressionAst]
    }).Count -eq 0) 'Launcher stream contract rejects indirect bootstrap assignments.'
    foreach ($name in @('ProgressPreference', 'ErrorActionPreference')) {
        $writes = @($bootstrapWrites | Where-Object {
            ($_.Left.VariablePath.UserPath -split ':')[-1] -ieq $name
        })
        Assert-Preflight ($writes.Count -eq 1 -and $writes[0].Left.VariablePath.UserPath -ceq $name) (
            "Launcher stream contract requires exactly one unscoped $name write.")
    }
    $indirectWrites = @($bootstrapAst.FindAll({
        param($node)
        ($node -is [Management.Automation.Language.UnaryExpressionAst] -and
            $node.TokenKind -in @('PlusPlus', 'MinusMinus', 'PostfixPlusPlus', 'PostfixMinusMinus')) -or
        ($node -is [Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -imatch '(^|\\)(Set-Variable|New-Variable|Clear-Variable|Remove-Variable|sv|nv|clv|rv|set)$')
    }, $true))
    $redirections = @($bootstrapAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.RedirectionAst]
    }, $true))
    Assert-Preflight ($indirectWrites.Count -eq 0 -and $redirections.Count -eq 0) (
        'Launcher stream contract rejects preference setters or bootstrap stream redirection.')

    $capAssignments = @($assignments | Where-Object {
        $_.Left -is [Management.Automation.Language.VariableExpressionAst] -and
        ($_.Left.VariablePath.UserPath -split ':')[-1] -ieq 'captureCapBytes'
    })
    Assert-Preflight (
        $capAssignments.Count -eq 1 -and
        (& $compact $capAssignments[0]) -ceq '$captureCapBytes=1048576L'
    ) 'Launcher stream contract must retain the unique one-MiB capture cap.'
    $drains = @($LauncherAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
        $node.Expression -is [Management.Automation.Language.TypeExpressionAst] -and
        $node.Expression.TypeName.FullName -ceq 'TL1C1bNextLauncherNativeV1' -and
        $node.Member.Value -ceq 'DrainAsync'
    }, $true))
    Assert-Preflight ($drains.Count -eq 2) 'Launcher stream contract requires exactly two bounded drains.'
    foreach ($role in @('StandardOutput', 'StandardError')) {
        $matchingDrains = @($drains | Where-Object {
            $_.Arguments.Count -eq 2 -and
            (& $compact $_.Arguments[0]) -ceq ('$process.' + $role + '.BaseStream') -and
            (& $compact $_.Arguments[1]) -ceq '[int]$captureCapBytes'
        })
        Assert-Preflight ($matchingDrains.Count -eq 1) "Launcher stream contract lost the bounded $role drain."
    }

    $logAssignments = @($assignments | Where-Object {
        $_.Left -is [Management.Automation.Language.VariableExpressionAst] -and
        ($_.Left.VariablePath.UserPath -split ':')[-1] -ieq 'logValue'
    })
    Assert-Preflight ($logAssignments.Count -eq 1 -and $logAssignments[0].Left.VariablePath.UserPath -ceq 'logValue') (
        'Launcher stream contract requires a unique logValue assignment.')
    $logTable = & $unwrap $logAssignments[0].Right
    Assert-Preflight ($logTable -is [Management.Automation.Language.HashtableAst]) (
        'Launcher stream contract requires a literal log hashtable.')
    $stderrPairs = @($logTable.KeyValuePairs | Where-Object {
        $_.Item1 -is [Management.Automation.Language.StringConstantExpressionAst] -and
        $_.Item1.Value -ceq 'stderr'
    })
    Assert-Preflight ($stderrPairs.Count -eq 1) 'Launcher stream contract requires exactly one log stderr field.'
    $stderrBranch = & $unwrap $stderrPairs[0].Item2
    Assert-Preflight (
        $stderrBranch -is [Management.Automation.Language.IfStatementAst] -and
        $stderrBranch.Clauses.Count -eq 1 -and $null -ne $stderrBranch.ElseClause -and
        (& $compact $stderrBranch.Clauses[0].Item1) -ceq '$null-eq$stderrResult' -and
        $stderrBranch.Clauses[0].Item2.Statements.Count -eq 1 -and
        (& $compact $stderrBranch.Clauses[0].Item2.Statements[0]) -ceq '$null'
    ) 'Launcher stream contract requires the exact nullable stderr log branch.'
    $stderrTable = & $unwrap $stderrBranch.ElseClause
    Assert-Preflight ($stderrTable -is [Management.Automation.Language.HashtableAst]) (
        'Launcher stream contract requires a literal stderr diagnostic hashtable.')
    $expectedFields = [ordered]@{
        total_byte_length = '[long]$stderrResult.TotalByteLength'
        captured_byte_length = '[long]$stderrResult.CapturedBytes.Length'
        sha256 = '''sha256:''+[string]$stderrResult.Sha256'
        overflowed = '[bool]$stderrResult.Overflowed'
        forced_closed = '[bool]$stderrForcedClosed'
        captured_prefix_base64 = '[Convert]::ToBase64String($stderrResult.CapturedBytes)'
        captured_prefix_sha256 = '''sha256:''+[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stderrResult.CapturedBytes)).ToLowerInvariant()'
        captured_prefix_byte_length = '[long]$stderrResult.CapturedBytes.Length'
        capture_is_prefix = '$true'
        uncaptured_byte_length = '[long]$stderrResult.TotalByteLength-[long]$stderrResult.CapturedBytes.Length'
    }
    Assert-Preflight ($stderrTable.KeyValuePairs.Count -eq $expectedFields.Count) (
        'Launcher stream contract stderr diagnostic field count drifted.')
    foreach ($name in $expectedFields.Keys) {
        $pairs = @($stderrTable.KeyValuePairs | Where-Object {
            $_.Item1 -is [Management.Automation.Language.StringConstantExpressionAst] -and
            $_.Item1.Value -ceq $name
        })
        Assert-Preflight ($pairs.Count -eq 1 -and (& $compact $pairs[0].Item2) -ceq $expectedFields[$name]) (
            "Launcher stream contract stderr diagnostic field drifted: $name")
    }

    $emptyGateCondition = '$stderrResult.Overflowed-or[long]$stderrResult.TotalByteLength-ne0L-or$stderrResult.CapturedBytes.Length-ne0'
    $emptyGates = @($LauncherAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.IfStatementAst]
    }, $true) | Where-Object {
        $_.Clauses.Count -eq 1 -and
        (& $compact $_.Clauses[0].Item1) -ceq $emptyGateCondition
    })
    Assert-Preflight (
        $emptyGates.Count -eq 1 -and $null -eq $emptyGates[0].ElseClause -and
        $emptyGates[0].Clauses[0].Item2.Statements.Count -eq 1 -and
        (& $compact $emptyGates[0].Clauses[0].Item2.Statements[0]) -ceq
            'throw''Helper stderr was not byte-empty for a passed summary.'''
    ) 'Launcher stream contract must preserve the exact nonempty-stderr rejection gate.'

    $bufferLoops = @($LauncherAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.ForEachStatementAst] -and
        $node.Variable.VariablePath.UserPath -ceq 'buffer'
    }, $true))
    $expectedBufferCollection = '@($summaryBytes,$expectedStdoutBytes,$(if($null-eq$stdoutResult){$null}else{,$stdoutResult.CapturedBytes}),$(if($null-eq$stderrResult){$null}else{,$stderrResult.CapturedBytes}))'
    Assert-Preflight (
        $bufferLoops.Count -eq 1 -and
        (& $compact $bufferLoops[0].Condition) -ceq $expectedBufferCollection -and
        $bufferLoops[0].Body.Statements.Count -eq 1 -and
        $bufferLoops[0].Body.Statements[0] -is [Management.Automation.Language.IfStatementAst]
    ) 'Launcher stream contract cleanup must retain both captured byte arrays by unary-comma reference.'
    $bufferGate = $bufferLoops[0].Body.Statements[0]
    Assert-Preflight (
        $bufferGate.Clauses.Count -eq 1 -and $null -eq $bufferGate.ElseClause -and
        (& $compact $bufferGate.Clauses[0].Item1) -ceq '$null-ne$buffer-and$buffer.Length-ne0' -and
        $bufferGate.Clauses[0].Item2.Statements.Count -eq 1 -and
        $bufferGate.Clauses[0].Item2.Statements[0] -is [Management.Automation.Language.TryStatementAst]
    ) 'Launcher stream contract cleanup must retain the guarded original-buffer clear.'
    $bufferTry = $bufferGate.Clauses[0].Item2.Statements[0]
    Assert-Preflight (
        $bufferTry.Body.Statements.Count -eq 1 -and
        (& $compact $bufferTry.Body.Statements[0]) -ceq '[Array]::Clear($buffer,0,$buffer.Length)'
    ) 'Launcher stream contract cleanup must clear the original buffer without rebinding or cloning.'
    return [pscustomobject][ordered]@{
        progress_suppressed_before_bootstrap = $true
        progress_preference_write_count = 1L
        error_action_stop_preserved = $true
        bootstrap_stderr_redirection_count = 0L
        diagnostic_prefix_bound = $true
        diagnostic_prefix_cap_bytes = 1048576L
        diagnostic_prefix_field_count = 5L
        captured_byte_length_field_preserved = $true
        empty_stderr_gate_preserved = $true
        empty_stderr_gate_count = 1L
        captured_array_cleanup_reference_shape_verified = $true
        captured_array_unary_comma_cleanup_count = 2L
        original_buffer_clear_preserved = $true
        launcher_invocation_count = 0L
        bootstrap_invocation_count = 0L
    }
}
