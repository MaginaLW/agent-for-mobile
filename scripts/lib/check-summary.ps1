#Requires -Version 7.5
# 离线门消费真实子套件结果；任何缺失、跳过或版本漂移均不得伪装成通过。
function Get-RunnerOfflinePassedCount {
    param([Parameter(Mandatory)][AllowEmptyString()][AllowEmptyCollection()][string[]]$Summaries)
    if ($Summaries.Count -eq 0) { throw 'runner 没有任何套件汇总。' }
    $total = 0L
    $matched = -1L
    for ($index = 0; $index -lt $Summaries.Count; $index++) {
        $line = $Summaries[$index]
        if ($line -cnotmatch '\A离线监督式 runner：([1-9][0-9]*) passed, 0 failed(?:（分片 ([1-9][0-9]*)/([1-9][0-9]*)，另 (0|[1-9][0-9]*) 条归其它分片）)?\z') {
            throw "runner 汇总缺失、空跑或失败：$line"
        }
        $passed = [long]$Matches[1]
        if ($Summaries.Count -eq 1) {
            if ($Matches.ContainsKey(2)) { throw '顺序 runner 不应携带分片标签。' }
        }
        else {
            if (-not $Matches.ContainsKey(2) -or [long]$Matches[2] -ne ($index + 1) -or
                [long]$Matches[3] -ne $Summaries.Count) { throw 'runner 分片身份或分片总数不一致。' }
            $caseCount = $passed + [long]$Matches[4]
            if ($matched -ge 0 -and $matched -ne $caseCount) { throw 'runner 各分片看到的用例总数不一致。' }
            $matched = $caseCount
        }
        $total += $passed
    }
    if ($matched -ge 0 -and $total -ne $matched) { throw 'runner 分片通过数未覆盖全部用例。' }
    return $total
}

function Assert-C1bRealBuildSmokeVerifierSummaryRawElement([Text.Json.JsonElement]$Element,[string]$Path){
    if($Element.ValueKind-eq[Text.Json.JsonValueKind]::Object){
        $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach($property in $Element.EnumerateObject()){
            $childPath="$Path/$($property.Name)"
            if(-not$names.Add($property.Name)){throw "C1b real build smoke verifier summary duplicate JSON property：$childPath"}
            Assert-C1bRealBuildSmokeVerifierSummaryRawElement $property.Value $childPath
        }
    }elseif($Element.ValueKind-eq[Text.Json.JsonValueKind]::Array){
        $index=0;foreach($child in $Element.EnumerateArray()){Assert-C1bRealBuildSmokeVerifierSummaryRawElement $child "$Path/$index";$index++}
    }elseif($Element.ValueKind-eq[Text.Json.JsonValueKind]::Number){
        $number=$Element.GetRawText();$parsed=0L
        if($number-cnotmatch'\A(?:0|-?[1-9][0-9]*)\z'-or-not[long]::TryParse($number,[Globalization.NumberStyles]::AllowLeadingSign,[Globalization.CultureInfo]::InvariantCulture,[ref]$parsed)){throw "C1b real build smoke verifier summary noncanonical Int64：$Path"}
    }
}
function Assert-C1bRealBuildSmokeVerifierSummary([string]$Stdout,[string]$Stderr,[string]$ExpectedPowerShellVersion){
    $operation='C1b real build smoke verifier offline tests'
    if ([string]::IsNullOrWhiteSpace($ExpectedPowerShellVersion)) { throw 'Expected PowerShell version is required.' }
    if($Stderr-cne''){throw "$operation stderr 必须 exact empty。"}
    if($Stdout-cnotmatch'\A([^\r\n]+)\r?\n\z'){throw "$operation stdout 必须 exact 单行 JSON。"};$raw=$Matches[1]
    $document=$null;try{$document=[Text.Json.JsonDocument]::Parse($raw);if($document.RootElement.ValueKind-ne[Text.Json.JsonValueKind]::Object){throw "$operation raw summary root 必须是 object。"};Assert-C1bRealBuildSmokeVerifierSummaryRawElement $document.RootElement ''}finally{if($null-ne$document){$document.Dispose()}}
    $summary=$raw|ConvertFrom-Json -Depth 20 -DateKind String -ErrorAction Stop
    if($summary-isnot[pscustomobject]){throw "$operation summary root 必须是 object。"}
    $actual=[string[]]@($summary.PSObject.Properties.Name);$expected=[string[]]@('schema','passed','failed','skipped','mutation_assertion_count','process_api_reference_count','path_capability_skip_count','captured_public_file_invocation_count','captured_public_file_rejection_count','direct_value_rejection_count','pwsh_version','failure_messages','skip_messages');[Array]::Sort($actual,[StringComparer]::Ordinal);[Array]::Sort($expected,[StringComparer]::Ordinal)
    if(($actual-join"`n")-cne($expected-join"`n")){throw "$operation summary keys 不 exact。"}
    foreach($name in @('passed','failed','skipped','mutation_assertion_count','process_api_reference_count','path_capability_skip_count','captured_public_file_invocation_count','captured_public_file_rejection_count','direct_value_rejection_count')){if($summary.PSObject.Properties[$name].Value-isnot[long]){throw "$operation $name 必须是 Int64。"}}
    if($summary.schema-isnot[string]-or$summary.pwsh_version-isnot[string]){throw "$operation schema/pwsh_version 必须是 strings。"}
    if($summary.failure_messages-isnot[Array]-or$summary.skip_messages-isnot[Array]){throw "$operation message fields 必须是 arrays。"}
    if($summary.schema-cne'tablet-layout-c1b-real-build-smoke-verifier-offline/v2'-or[long]$summary.failed-ne0-or([long]$summary.passed+[long]$summary.skipped)-ne19-or([long]$summary.mutation_assertion_count+[long]$summary.skipped)-ne217-or([long]$summary.captured_public_file_invocation_count+[long]$summary.skipped)-ne209-or([long]$summary.captured_public_file_rejection_count+[long]$summary.skipped)-ne208-or[long]$summary.direct_value_rejection_count-ne9-or[long]$summary.mutation_assertion_count-ne([long]$summary.captured_public_file_rejection_count+[long]$summary.direct_value_rejection_count)-or[long]$summary.captured_public_file_invocation_count-ne([long]$summary.captured_public_file_rejection_count+1)-or[long]$summary.process_api_reference_count-ne0-or[long]$summary.path_capability_skip_count-ne[long]$summary.skipped-or[long]$summary.skipped-lt0-or[long]$summary.skipped-gt2-or$summary.pwsh_version-cne$ExpectedPowerShellVersion-or@($summary.failure_messages).Count-ne0-or@($summary.skip_messages).Count-ne[long]$summary.skipped){throw "$operation summary 值不 exact：$raw"}
    foreach($message in @($summary.failure_messages)+@($summary.skip_messages)){if($message-isnot[string]-or[string]::IsNullOrWhiteSpace([string]$message)){throw "$operation message element 非法。"}}
    if ([long]$summary.skipped -ne 0) {
        throw "C1b 符号链接反例未运行：$($summary.skipped) 项；请开启 Windows 开发者模式或使用具备创建符号链接特权的终端。未运行不能记为全绿。"
    }
}
