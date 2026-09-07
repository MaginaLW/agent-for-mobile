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
