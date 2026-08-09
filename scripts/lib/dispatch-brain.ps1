#Requires -Version 7

function ConvertTo-DispatchTomlString {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    return '"' + ($Value -replace '\\', '\\' -replace '"', '\"') + '"'
}

function ConvertTo-DispatchTomlStringArray {
    param([AllowEmptyCollection()][object[]]$Values = @())
    return '[' + ((@($Values) | ForEach-Object { ConvertTo-DispatchTomlString ([string]$_) }) -join ',') + ']'
}

function Get-DispatchPropertyValue {
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )
    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Resolve-DispatchTrustedCodexExecutable {
    [CmdletBinding()]
    param()

    $localAppData = [IO.Path]::GetFullPath([Environment]::GetFolderPath('LocalApplicationData'))
    $binRoot = Join-Path $localAppData 'OpenAI\Codex\bin'
    foreach ($directory in @(
        $localAppData,
        (Join-Path $localAppData 'OpenAI'),
        (Join-Path $localAppData 'OpenAI\Codex'),
        $binRoot
    )) {
        $item = Get-Item -LiteralPath $directory -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            -not [string]::IsNullOrWhiteSpace([string]$item.LinkType)) {
            throw 'Codex 官方 bin 路径含 reparse/link，拒绝启动。'
        }
    }

    $candidate = Get-ChildItem -LiteralPath $binRoot -Directory -Force |
        Sort-Object Name -Descending |
        ForEach-Object {
            if (($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                -not [string]::IsNullOrWhiteSpace([string]$_.LinkType)) { return }
            $path = Join-Path $_.FullName 'codex.exe'
            if (Test-Path -LiteralPath $path -PathType Leaf) { return (Get-Item -LiteralPath $path -Force) }
        } | Select-Object -First 1
    if ($null -eq $candidate -or
        ($candidate.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        -not [string]::IsNullOrWhiteSpace([string]$candidate.LinkType)) {
        throw '找不到官方桌面应用 bundled codex.exe。'
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $candidate.FullName
    if ($signature.Status -ne 'Valid' -or
        [string]$signature.SignerCertificate.Subject -notmatch 'CN="?OpenAI OpCo, LLC"?') {
        throw 'codex.exe 签名不是有效的 OpenAI OpCo 签名。'
    }

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $candidate.FullName
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.ArgumentList.Add('--version')
    # 版本探针发生在 bearer 构造前，也不需要认证、网络或用户配置；不能让它因为
    # ProcessStartInfo 默认继承而先拿到宿主任意 secret。
    $versionEnvironment = @{}
    foreach ($name in @('SystemRoot','WINDIR','ComSpec','OS','TEMP','TMP','PATH','PATHEXT')) {
        if ($start.Environment.ContainsKey($name)) { $versionEnvironment[$name] = $start.Environment[$name] }
    }
    $start.Environment.Clear()
    foreach ($entry in $versionEnvironment.GetEnumerator()) {
        $start.Environment[[string]$entry.Key] = [string]$entry.Value
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start() -or -not $process.WaitForExit(5000)) {
            try { if (-not $process.HasExited) { $process.Kill($true) } } catch {}
            throw 'codex.exe --version 未在 5 秒内成功返回。'
        }
        $version = $process.StandardOutput.ReadToEnd().Trim()
        if ($process.ExitCode -ne 0 -or $version -notmatch '^codex-cli 0\.147(?:\.|$)') {
            throw 'codex.exe 版本不符合已验证的 0.147 JSONL 契约。'
        }
    }
    finally { $process.Dispose() }
    return $candidate.FullName
}

function New-DispatchCodexLaunchSpec {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Profile,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$WorkspacePath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Model,
        [Parameter(Mandatory)][bool]$ModelWasExplicit,
        [Parameter(Mandatory)][ValidateSet(1,2)][int]$Leg,
        [string]$CodexExecutableOverride = ''
    )

    $codexExecutable = if ([string]::IsNullOrWhiteSpace($CodexExecutableOverride)) {
        Resolve-DispatchTrustedCodexExecutable
    } else { $CodexExecutableOverride }

    try {
        $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8 -ErrorAction Stop |
            ConvertFrom-Json -Depth 30 -ErrorAction Stop
    }
    catch { throw "无法读取 Codex MCP 配置：$($_.Exception.Message)" }

    $serverName = [string]$Profile.Name
    $server = $config.mcpServers.PSObject.Properties[$serverName].Value
    if ($null -eq $server) { throw "Codex MCP 配置缺少 mcpServers.$serverName。" }

    $arguments = [Collections.Generic.List[string]]::new()
    $disabledFeatures = @(
        'apps','browser_use','browser_use_external','browser_use_full_cdp_access','computer_use','goals','hooks','image_generation',
        'code_mode','code_mode_buffered_exec','code_mode_only','in_app_browser','memories',
        'multi_agent','multi_agent_v2','plugins','remote_plugin',
        'shell_snapshot','shell_tool','skill_mcp_dependency_install','skill_search','tool_call_mcp_elicitation',
        'tool_suggest','workspace_dependencies','plugin_hooks'
    )
    foreach ($argument in @(
        'exec','--json','--ephemeral','--ignore-user-config','--ignore-rules','--strict-config',
        '--skip-git-repo-check','-C',$WorkspacePath,'--sandbox','read-only',
        '-c','mcp_servers={}',
        '-c','project_doc_max_bytes=0','-c','tools.web_search=false',
        '-c','web_search="disabled"','-c','agents.enabled=false','-c','forced_login_method="chatgpt"',
        '-c','shell_environment_policy.inherit="none"',
        '-c',"mcp_servers.$serverName.enabled=true",
        '-c',"mcp_servers.$serverName.required=true",
        '-c',"mcp_servers.$serverName.default_tools_approval_mode=`"approve`""
    )) { $arguments.Add($argument) }
    foreach ($feature in $disabledFeatures) {
        $arguments.Add('--disable')
        $arguments.Add($feature)
    }

    $sensitiveEnvironment = @{}
    if ([string]$server.type -ceq 'http') {
        if ($serverName -cne 'gateway' -or [string]$server.url -cne 'http://127.0.0.1:8848/mcp') {
            throw 'Codex HTTP MCP 只接受本机 127.0.0.1 gateway。'
        }
        $authorization = [string]$server.headers.Authorization
        if ($authorization -notmatch '(?i)^Bearer\s+([^\s]+)$') {
            throw "Codex MCP 配置 mcpServers.$serverName 缺少有效 Bearer token。"
        }
        $token = [string]$Matches[1]
        $tokenEnvironmentName = 'AGENT_MOBILE_MCP_' + [guid]::NewGuid().ToString('N').ToUpperInvariant()
        try { $sensitiveEnvironment[$tokenEnvironmentName] = $token }
        finally {
            # token 已转移到一次性 child env map；异常路径也立刻清掉 JSON 对象树重复引用。
            $server.headers.Authorization = ''
        }
        $arguments.Add('-c')
        $arguments.Add("mcp_servers.$serverName.url=$(ConvertTo-DispatchTomlString ([string]$server.url))")
        $arguments.Add('-c')
        $arguments.Add("mcp_servers.$serverName.bearer_token_env_var=$(ConvertTo-DispatchTomlString $tokenEnvironmentName)")
        $timeoutSeconds = [int][math]::Ceiling(([double]$server.timeout) / 1000.0)
        if ($timeoutSeconds -lt 1) { throw "Codex MCP 配置 mcpServers.$serverName timeout 非法。" }
        $arguments.Add('-c')
        $arguments.Add("mcp_servers.$serverName.tool_timeout_sec=$timeoutSeconds")
        $token = $null
        $authorization = $null
    }
    elseif ([string]$server.type -ceq 'stdio') {
        if ($serverName -cne 'mobile' -or [IO.Path]::GetFileName([string]$server.command) -notin @('npx','npx.cmd') -or
            @($server.args).Count -ne 2 -or [string]$server.args[0] -cne '-y' -or
            [string]$server.args[1] -cne '@mobilenext/mobile-mcp@0.0.62' -or
            $null -ne $server.PSObject.Properties['env'] -or $null -ne $server.PSObject.Properties['cwd']) {
            throw 'Codex mobile MCP 只接受锁定的 npx -y @mobilenext/mobile-mcp@0.0.62 stdio 配置。'
        }
        $npxBin = Get-Command npx -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $npxBin) { throw '找不到 npx 可执行文件。' }
        $arguments.Add('-c')
        $arguments.Add("mcp_servers.$serverName.command=$(ConvertTo-DispatchTomlString ([string]$npxBin.Source))")
        $arguments.Add('-c')
        $arguments.Add("mcp_servers.$serverName.args=$(ConvertTo-DispatchTomlStringArray @($server.args))")
        $arguments.Add('-c')
        $arguments.Add('mcp_servers.mobile.env={MOBILEMCP_DISABLE_TELEMETRY="1"}')
        $mobileEnabledTools = @(
            'mobile_list_available_devices','mobile_list_apps','mobile_launch_app','mobile_terminate_app',
            'mobile_get_screen_size','mobile_click_on_screen_at_coordinates',
            'mobile_double_tap_on_screen','mobile_long_press_on_screen_at_coordinates',
            'mobile_list_elements_on_screen','mobile_press_button','mobile_open_url',
            'mobile_swipe_on_screen','mobile_type_keys','mobile_take_screenshot','mobile_set_orientation',
            'mobile_get_orientation','mobile_list_crashes','mobile_get_crash'
        )
        if ($Leg -eq 2) { $mobileEnabledTools += 'mobile_uninstall_app' }
        $arguments.Add('-c')
        $arguments.Add("mcp_servers.mobile.enabled_tools=$(ConvertTo-DispatchTomlStringArray $mobileEnabledTools)")
    }
    else { throw "Codex MCP 配置 mcpServers.$serverName.type 不受支持。" }

    if ($ModelWasExplicit) {
        $arguments.Add('--model')
        $arguments.Add($Model)
    }
    # `-` 明确要求从已经过路径验证的 prompt 文件读取，而不是把任务正文放进 argv。
    $arguments.Add('-')

    $config = $null
    $server = $null
    return [pscustomobject]@{
        Executable = [string]$codexExecutable
        Arguments = [string[]]$arguments.ToArray()
        SensitiveEnvironment = $sensitiveEnvironment
        LedgerModel = $(if ($ModelWasExplicit) { $Model } else { '' })
    }
}

function ConvertFrom-DispatchResultEnvelope {
    param($Result)
    if ($null -eq $Result) { return $null }
    if ($Result -is [string]) {
        try { return $Result | ConvertFrom-Json -Depth 30 -ErrorAction Stop }
        catch { return $null }
    }
    $contentProperty = $Result.PSObject.Properties['content']
    if ($null -ne $contentProperty) {
        $texts = @($contentProperty.Value | Where-Object {
            (Get-DispatchPropertyValue $_ 'type') -eq 'text' -and
            (Get-DispatchPropertyValue $_ 'text') -is [string]
        })
        if ($texts.Count -eq 1) {
            try { return (Get-DispatchPropertyValue $texts[0] 'text') | ConvertFrom-Json -Depth 30 -ErrorAction Stop }
            catch { return $null }
        }
    }
    $structuredProperty = $Result.PSObject.Properties['structured_content']
    if ($null -ne $structuredProperty) { return $structuredProperty.Value }
    return $null
}

function ConvertTo-DispatchMobileTransportMarker {
    param([Parameter(Mandatory)]$Result)

    $isError = Get-DispatchPropertyValue $Result 'isError'
    if ($null -eq $isError) { $isError = Get-DispatchPropertyValue $Result 'is_error' }
    if ($isError -eq $true) { throw 'Codex mobile MCP result 标记为 isError。' }
    $contentProperty = $Result.PSObject.Properties['content']
    if ($null -eq $contentProperty) { throw 'Codex mobile MCP result 缺少 content。' }
    $blocks = @($contentProperty.Value)
    if ($blocks.Count -lt 1) { throw 'Codex mobile MCP result content 不能为空。' }

    $contentTypes = [Collections.Generic.List[string]]::new()
    foreach ($block in $blocks) {
        $type = [string](Get-DispatchPropertyValue $block 'type')
        switch ($type) {
            'text' {
                $text = Get-DispatchPropertyValue $block 'text'
                if (-not ($text -is [string]) -or [string]::IsNullOrEmpty([string]$text)) {
                    throw 'Codex mobile MCP text block 缺少正文。'
                }
            }
            'image' {
                $data = Get-DispatchPropertyValue $block 'data'
                $mimeType = Get-DispatchPropertyValue $block 'mimeType'
                if ($null -eq $mimeType) { $mimeType = Get-DispatchPropertyValue $block 'mime_type' }
                if (-not ($data -is [string]) -or [string]::IsNullOrWhiteSpace([string]$data) -or
                    -not ($mimeType -is [string]) -or [string]$mimeType -notmatch '^image/[A-Za-z0-9.+-]+$') {
                    throw 'Codex mobile MCP image block 缺少合法 data/mimeType。'
                }
                $decoded = $null
                try { $decoded = [Convert]::FromBase64String([string]$data) }
                catch { throw 'Codex mobile MCP image block 不是合法 base64。' }
                finally {
                    if ($null -ne $decoded -and $decoded.Length -gt 0) { [Array]::Clear($decoded, 0, $decoded.Length) }
                }
            }
            default { throw "Codex mobile MCP result 含未知 content block：$type" }
        }
        $contentTypes.Add($type)
    }
    # 只返回形状证明，不保留 text/image/base64 原文。
    return [pscustomobject]@{
        Transport='mobile-content'
        ContentCount=$contentTypes.Count
        ContentTypes=[string[]]$contentTypes.ToArray()
    }
}

function Read-DispatchTraceTranscript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TracePath,
        [Parameter(Mandatory)][ValidateSet('claude','codex')][string]$Brain
    )

    if (-not (Test-Path -LiteralPath $TracePath -PathType Leaf)) {
        throw "trace 不存在：$TracePath"
    }

    if ($Brain -eq 'claude') {
        $callsById = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        $calls = [Collections.Generic.List[object]]::new()
        $terminal = $null
        $terminalSeen = $false
        $eventOrdinal = 0
        foreach ($line in Get-Content -LiteralPath $TracePath -Encoding utf8) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $eventOrdinal++
            if ($terminalSeen) { throw 'Claude trace 的 result 终态之后仍有事件。' }
            try { $event = $line | ConvertFrom-Json -Depth 40 -ErrorAction Stop }
            catch { throw 'Claude trace 含无法解析的非空 JSON 行。' }
            switch ([string]$event.type) {
                'assistant' {
                    foreach ($content in @($event.message.content)) {
                        if ($content.type -ne 'tool_use') { continue }
                        $id = [string]$content.id
                        if ([string]::IsNullOrWhiteSpace($id) -or $callsById.ContainsKey($id)) {
                            throw 'Claude trace 含缺失或重复的 tool_use id。'
                        }
                        $rawName = [string]$content.name
                        $server = ''
                        $name = $rawName
                        $match = [regex]::Match($rawName, '^mcp__([^_]+)__(.+)$')
                        if ($match.Success) { $server = $match.Groups[1].Value; $name = $match.Groups[2].Value }
                        if ($calls.Count -gt 0 -and $calls[$calls.Count - 1].ResultCount -ne 1) {
                            throw 'Claude trace 在上一调用完成前启动了下一调用。'
                        }
                        $call = [pscustomobject]@{
                            Id=$id; Server=$server; Name=$name; RawName=$rawName
                            Input=(Get-DispatchPropertyValue $content 'input')
                            ResultEnvelope=$null; ResultCount=0; Outcome='started'
                            Ordinal=$calls.Count; StartedOrdinal=$eventOrdinal; CompletedOrdinal=$null
                            CompletedBeforeNext=$false
                        }
                        $callsById.Add($id, $call)
                        $calls.Add($call)
                    }
                }
                'user' {
                    foreach ($content in @($event.message.content)) {
                        if ($content.type -ne 'tool_result') { continue }
                        $id = [string]$content.tool_use_id
                        if ([string]::IsNullOrWhiteSpace($id) -or -not $callsById.ContainsKey($id)) {
                            throw 'Claude trace 含孤儿 tool_result。'
                        }
                        $call = $callsById[$id]
                        $call.ResultCount++
                        if ($call.ResultCount -ne 1) { throw 'Claude trace 含重复 tool_result。' }
                        $call.ResultEnvelope = ConvertFrom-DispatchResultEnvelope $content
                        $isError = Get-DispatchPropertyValue $content 'is_error'
                        $call.Outcome = $(if ($isError -eq $true) { 'failed' } else { 'success' })
                        $call.CompletedOrdinal = $eventOrdinal
                    }
                }
                'result' {
                    if ($null -ne $terminal) { throw 'Claude trace 含多个 result 终态。' }
                    $terminal = $event
                    $terminalSeen = $true
                }
                { $_ -in @('system','rate_limit_event') } { }
                default { throw "Claude trace 含未知事件类型：$($event.type)" }
            }
        }
        if ($null -eq $terminal) { throw 'Claude trace 缺少唯一 result 终态。' }
        foreach ($call in $calls) {
            if ($call.ResultCount -ne 1) { throw "Claude trace 的调用 $($call.Id) 没有唯一结果。" }
        }
        for ($index = 0; $index -lt $calls.Count; $index++) {
            $nextOrdinal = if ($index + 1 -lt $calls.Count) {
                [int]$calls[$index + 1].StartedOrdinal
            } else { $eventOrdinal }
            $calls[$index].CompletedBeforeNext = [int]$calls[$index].CompletedOrdinal -lt $nextOrdinal
            if (-not $calls[$index].CompletedBeforeNext) {
                throw "Claude trace 的调用 $($calls[$index].Id) 未在下一事件边界前完成。"
            }
        }
        $usage = Get-DispatchPropertyValue $terminal 'usage'
        $terminalSessionId = Get-DispatchPropertyValue $terminal 'session_id'
        $terminalSubtype = Get-DispatchPropertyValue $terminal 'subtype'
        $terminalResult = Get-DispatchPropertyValue $terminal 'result'
        return [pscustomobject]@{
            Brain='claude'; Schema='claude-stream-json-v1'; SessionId=[string]$terminalSessionId
            Terminal=[pscustomobject]@{
                Type='result'; Status=[string]$terminalSubtype
                Success=([string]$terminalSubtype -ceq 'success')
            }
            FinalText=$(if ($terminalResult -is [string]) { [string]$terminalResult } else { '' })
            Usage=[pscustomobject]@{
                InputTokens=$(if ($null -ne $usage -and $null -ne $usage.PSObject.Properties['input_tokens']) { [long]$usage.input_tokens } else { $null })
                CachedInputTokens=$(if ($null -ne $usage -and $null -ne $usage.PSObject.Properties['cache_read_input_tokens']) { [long]$usage.cache_read_input_tokens } else { $null })
                OutputTokens=$(if ($null -ne $usage -and $null -ne $usage.PSObject.Properties['output_tokens']) { [long]$usage.output_tokens } else { $null })
                CacheWriteTokens=$(if ($null -ne $usage -and $null -ne $usage.PSObject.Properties['cache_creation_input_tokens']) { [long]$usage.cache_creation_input_tokens } else { $null })
            }
            Turns=$(if ($null -ne $terminal.PSObject.Properties['num_turns']) { [int](Get-DispatchPropertyValue $terminal 'num_turns') } else { $null })
            CostUsd=$(if ($null -ne $terminal.PSObject.Properties['total_cost_usd']) { [double](Get-DispatchPropertyValue $terminal 'total_cost_usd') } else { $null })
            Calls=[object[]]$calls.ToArray()
        }
    }

    $callsById = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $calls = [Collections.Generic.List[object]]::new()
    $sessionId = ''
    $threadStarted = 0
    $turnStarted = 0
    $turnTerminals = 0
    $terminalSeen = $false
    # 仅在解析期间保留正文与 ordinal；canonical 只暴露最终正文，避免中间说明扩散到
    # console/ledger。ordinal 用来证明最终正文发生在全部 MCP completed 之后。
    $finalMessages = [Collections.Generic.List[object]]::new()
    $usage = $null
    $sawCodexError = $false
    $eventOrdinal = 0
    $terminalOrdinal = $null

    foreach ($line in Get-Content -LiteralPath $TracePath -Encoding utf8) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $eventOrdinal++
        if ($terminalSeen) { throw 'Codex trace 的 turn.completed 终态之后仍有事件。' }
        try { $event = $line | ConvertFrom-Json -Depth 40 -ErrorAction Stop }
        catch { throw 'Codex trace 含无法解析的非空 JSON 行。' }
        switch ([string]$event.type) {
            'thread.started' {
                $threadStarted++
                if ($threadStarted -ne 1 -or $turnStarted -gt 0 -or $calls.Count -gt 0) {
                    throw 'Codex trace 的 thread.started 缺失、重复或错序。'
                }
                $sessionId = [string]$event.thread_id
                if ([string]::IsNullOrWhiteSpace($sessionId)) { throw 'Codex thread.started 缺少 thread_id。' }
            }
            'turn.started' {
                if ($threadStarted -ne 1 -or ++$turnStarted -ne 1) { throw 'Codex turn.started 重复或错序。' }
            }
            'item.started' {
                if ($threadStarted -ne 1 -or $turnStarted -ne 1) { throw 'Codex item.started 早于 turn.started。' }
                $item = $event.item
                if ([string]$item.type -eq 'reasoning') { continue }
                if ([string]$item.type -ne 'mcp_tool_call') {
                    throw "Codex trace 含未授权 item.started 类型：$($item.type)"
                }
                $id = [string]$item.id
                if ([string]::IsNullOrWhiteSpace($id) -or $callsById.ContainsKey($id)) {
                    throw 'Codex trace 含缺失或重复的 mcp_tool_call id。'
                }
                if ($calls.Count -gt 0 -and $calls[$calls.Count - 1].ResultCount -ne 1) {
                    throw 'Codex trace 在上一 MCP 调用 completed 前启动了下一调用。'
                }
                $call = [pscustomobject]@{
                    Id=$id; Server=[string]$item.server; Name=[string]$item.tool
                    RawName="mcp__$($item.server)__$($item.tool)"; Input=$item.arguments
                    ResultEnvelope=$null; ResultCount=0; Outcome='started'
                    Ordinal=$calls.Count; StartedOrdinal=$eventOrdinal; CompletedOrdinal=$null
                    CompletedBeforeNext=$false
                    InputCanonical=($item.arguments | ConvertTo-Json -Compress -Depth 40)
                }
                if ([string]::IsNullOrWhiteSpace($call.Server) -or [string]::IsNullOrWhiteSpace($call.Name)) {
                    throw 'Codex mcp_tool_call 缺少 server/tool。'
                }
                $callsById.Add($id, $call)
                $calls.Add($call)
            }
            'item.completed' {
                if ($threadStarted -ne 1) { throw 'Codex item.completed 早于 thread.started。' }
                $item = $event.item
                if ([string]$item.type -eq 'error') {
                    $sawCodexError = $true
                    continue
                }
                if ($turnStarted -ne 1) { throw 'Codex item.completed 早于 turn.started。' }
                switch ([string]$item.type) {
                    'reasoning' { continue }
                    'agent_message' {
                        if (-not ($item.text -is [string])) { throw 'Codex agent_message 缺少文本。' }
                        $finalMessages.Add([pscustomobject]@{
                            Text=[string]$item.text
                            Ordinal=$eventOrdinal
                        })
                    }
                    'mcp_tool_call' {
                        $id = [string]$item.id
                        if ([string]::IsNullOrWhiteSpace($id) -or -not $callsById.ContainsKey($id)) {
                            throw 'Codex trace 含孤儿 mcp_tool_call completed。'
                        }
                        $call = $callsById[$id]
                        if ($call.Server -cne [string]$item.server -or $call.Name -cne [string]$item.tool) {
                            throw "Codex mcp_tool_call $id 的 started/completed 身份不一致。"
                        }
                        $completedInput = $item.arguments | ConvertTo-Json -Compress -Depth 40
                        if ($call.InputCanonical -cne $completedInput) {
                            throw "Codex mcp_tool_call $id 的 started/completed arguments 不一致。"
                        }
                        $call.ResultCount++
                        if ($call.ResultCount -ne 1) { throw "Codex mcp_tool_call $id 重复 completed。" }
                        $call.CompletedOrdinal = $eventOrdinal
                        $itemStatus = Get-DispatchPropertyValue $item 'status'
                        $itemError = Get-DispatchPropertyValue $item 'error'
                        if ([string]$itemStatus -cne 'completed' -or $null -ne $itemError) {
                            $call.Outcome = 'failed'
                            $call.ResultEnvelope = $itemError
                            continue
                        }
                        $rawResult = Get-DispatchPropertyValue $item 'result'
                        $call.ResultEnvelope = if ($call.Server -ceq 'mobile') {
                            ConvertTo-DispatchMobileTransportMarker $rawResult
                        }
                        else { ConvertFrom-DispatchResultEnvelope $rawResult }
                        if ($null -eq $call.ResultEnvelope) { throw "Codex mcp_tool_call $id 缺少结构化结果。" }
                        $call.Outcome = 'success'
                    }
                    default { throw "Codex trace 含未授权 item.completed 类型：$($item.type)" }
                }
            }
            'turn.completed' {
                if ($threadStarted -ne 1 -or $turnStarted -ne 1 -or ++$turnTerminals -ne 1) {
                    throw 'Codex turn.completed 重复或错序。'
                }
                $usage = Get-DispatchPropertyValue $event 'usage'
                $terminalSeen = $true
                $terminalOrdinal = $eventOrdinal
                $terminal = [pscustomobject]@{ Type='turn.completed'; Status='success'; Success=$true; Code='' }
            }
            'turn.failed' {
                if ($threadStarted -ne 1 -or ++$turnTerminals -ne 1) { throw 'Codex turn.failed 重复或错序。' }
                $terminalSeen = $true
                $terminalOrdinal = $eventOrdinal
                $terminal = [pscustomobject]@{
                    Type='turn.failed'; Status='failed'; Success=$false
                    Code=$(if ($sawCodexError) { 'codex-error' } else { 'turn-failed' })
                }
            }
            'error' {
                $sawCodexError = $true
            }
            default { throw "Codex trace 含未知事件类型：$($event.type)" }
        }
    }
    if ($threadStarted -ne 1 -or $turnTerminals -ne 1) { throw 'Codex trace 缺少唯一 thread/turn 终态。' }
    if ($terminal.Success -and $sawCodexError) { throw 'Codex 成功终态之前出现 error diagnostics。' }
    if ($terminal.Success -and $finalMessages.Count -lt 1) { throw 'Codex trace 缺少 agent_message 终态正文。' }
    for ($index = 0; $index -lt $calls.Count; $index++) {
        $call = $calls[$index]
        if ($call.ResultCount -ne 1) { throw "Codex mcp_tool_call $($call.Id) 缺少唯一 completed。" }
        $nextOrdinal = if ($index + 1 -lt $calls.Count) {
            [int]$calls[$index + 1].StartedOrdinal
        } else { [int]$terminalOrdinal }
        $call.CompletedBeforeNext = [int]$call.CompletedOrdinal -lt $nextOrdinal
        if (-not $call.CompletedBeforeNext) {
            throw "Codex mcp_tool_call $($call.Id) 未在下一调用/终态前 completed。"
        }
    }
    if ($terminal.Success) {
        $lastMessage = $finalMessages[$finalMessages.Count - 1]
        $latestCallCompletion = -1
        foreach ($call in $calls) {
            $latestCallCompletion = [math]::Max($latestCallCompletion, [int]$call.CompletedOrdinal)
        }
        if ([int]$lastMessage.Ordinal -le $latestCallCompletion -or
            [int]$lastMessage.Ordinal -ge [int]$terminalOrdinal) {
            throw 'Codex 最后 agent_message 必须晚于全部 MCP completed 且早于 turn.completed。'
        }
    }
    if ($terminal.Success) {
        if ($null -eq $usage) { throw 'Codex turn.completed 缺少 usage。' }
        foreach ($field in @('input_tokens','cached_input_tokens','output_tokens')) {
            $property = $usage.PSObject.Properties[$field]
            if ($null -eq $property -or [long]$property.Value -lt 0) {
                throw "Codex turn.completed usage.$field 缺失或非法。"
            }
        }
    }
    return [pscustomobject]@{
        Brain='codex'; Schema='codex-jsonl-v1'; SessionId=$sessionId
        Terminal=$terminal
        FinalText=$(if ($finalMessages.Count -gt 0) { [string]$finalMessages[$finalMessages.Count - 1].Text } else { '' })
        Usage=[pscustomobject]@{
            InputTokens=$(if ($null -ne $usage -and $null -ne $usage.PSObject.Properties['input_tokens']) { [long]$usage.input_tokens } else { $null })
            CachedInputTokens=$(if ($null -ne $usage -and $null -ne $usage.PSObject.Properties['cached_input_tokens']) { [long]$usage.cached_input_tokens } else { $null })
            OutputTokens=$(if ($null -ne $usage -and $null -ne $usage.PSObject.Properties['output_tokens']) { [long]$usage.output_tokens } else { $null })
            CacheWriteTokens=$(if ($null -ne $usage -and $null -ne $usage.PSObject.Properties['cache_write_input_tokens']) { [long]$usage.cache_write_input_tokens } else { $null })
        }
        Turns=1; CostUsd=$null; Calls=[object[]]$calls.ToArray()
    }
}
