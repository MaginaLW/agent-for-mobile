#Requires -Version 7.5
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$pwshPath = (Get-Process -Id $PID).Path
$passed = 0

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Throws([scriptblock]$Body, [string]$ExpectedPattern) {
    $err = $null
    try { & $Body | Out-Null } catch { $err = $_ }
    Assert-True ($null -ne $err) "预期抛出异常 /$ExpectedPattern/，但实际未抛出。"
    Assert-True ($err.Exception.Message -match $ExpectedPattern) "异常消息不匹配 /$ExpectedPattern/：$($err.Exception.Message)"
}

function Test-Case([string]$Name, [scriptblock]$Body) {
    & $Body
    $script:passed++
}

function Get-DeeplinkMarkdownSchemes([string]$MarkdownSection) {
    $appToPkg = @{
        '小红书' = 'com.xingin.xhs'
        '京东'   = 'com.jingdong.app.mall'
        '淘宝'   = 'com.taobao.taobao'
        '天猫'   = 'com.tmall.wireless'
    }
    $results = [Collections.Generic.List[object]]::new()
    foreach ($line in ($MarkdownSection -split "`r?`n")) {
        if ($line -notmatch '^\|') { continue }
        $cols = @($line.Split('|') | ForEach-Object { $_.Trim() })
        if ($cols.Count -lt 5) { continue }
        $appName = $cols[1]
        if (-not $appToPkg.ContainsKey($appName)) { continue }
        $cell = $cols[2]
        foreach ($m in [regex]::Matches($cell, '`([^`]+)`')) {
            $raw = $m.Groups[1].Value
            if ($raw -match '^([a-z][a-z0-9+.-]*://[^\s?`<]*)') {
                $prefix = $Matches[1]
                $results.Add([pscustomobject]@{
                    App           = $appName
                    ExpectPackage = $appToPkg[$appName]
                    Prefix        = $prefix
                })
            }
        }
    }
    return @($results)
}

function Assert-SkillPackSync {
    param(
        [Parameter(Mandatory)]$AppsJson,
        [Parameter(Mandatory)]$DeeplinksJson,
        [Parameter(Mandatory)]$SafetyJson,
        [Parameter(Mandatory)][string]$DeeplinksMd,
        [Parameter(Mandatory)][xml]$ManifestXml
    )

    $entries = @($DeeplinksJson.entries)
    $prefixes = @($entries | ForEach-Object { [string]$_.prefix })
    Assert-True ($prefixes.Count -eq @($prefixes | Sort-Object -Unique).Count) 'deeplinks.json 存在重复 prefix。'

    $blockedPrefixes = @($SafetyJson.blocked_app_prefixes)
    $aliasMap = @{}
    foreach ($p in $AppsJson.aliases.PSObject.Properties) {
        $aliasMap[$p.Name] = [string]$p.Value
    }
    $registeredPackages = @($aliasMap.Values)

    $byPrefix = @{}
    foreach ($e in $entries) {
        $pkg = [string]$e.expect_package
        Assert-True ($pkg -in $registeredPackages) "deeplinks.json expect_package=$pkg 未在 apps.json aliases 注册。"
        foreach ($bp in $blockedPrefixes) {
            Assert-True (-not $pkg.StartsWith([string]$bp, [StringComparison]::Ordinal)) "deeplinks.json 包含黑名单包名：$pkg"
        }
        $ver = [string]$e.verified
        Assert-True ($ver -ceq '' -or $ver -match '^\d{4}-\d{2}-\d{2}$') "deeplinks.json verified 格式非法：$($e.prefix) -> $ver"
        $byPrefix[[string]$e.prefix] = $e
    }

    $candidateHeader = '## 云端查阅候选'
    $principleHeader = '## 使用原则'
    $candIdx = $DeeplinksMd.IndexOf($candidateHeader, [StringComparison]::Ordinal)
    $prinIdx = $DeeplinksMd.IndexOf($principleHeader, [StringComparison]::Ordinal)
    Assert-True ($candIdx -gt 0 -and $prinIdx -gt $candIdx) 'deeplinks.md 缺少预期章节边界。'

    $mainSection = $DeeplinksMd.Substring(0, $candIdx)
    $candSection = $DeeplinksMd.Substring($candIdx, $prinIdx - $candIdx)

    $mainSchemes = Get-DeeplinkMarkdownSchemes $mainSection
    Assert-True ($mainSchemes.Count -ge 1) 'deeplinks.md 正表未解析出任何 App 深链。'
    foreach ($item in $mainSchemes) {
        Assert-True ($byPrefix.ContainsKey($item.Prefix)) "deeplinks.md 正表深链未登记于 deeplinks.json：$($item.Prefix)"
        $entry = $byPrefix[$item.Prefix]
        Assert-True ([string]$entry.expect_package -ceq $item.ExpectPackage) "expect_package 不一致：$($item.Prefix)"
        Assert-True ([string]$entry.verified -match '^\d{4}-\d{2}-\d{2}$') "正表已实测深链缺少有效日期：$($item.Prefix)"
    }

    $candSchemes = Get-DeeplinkMarkdownSchemes $candSection
    Assert-True ($candSchemes.Count -ge 5) 'deeplinks.md 候选表未解析出预期数量的非黑名单深链。'
    foreach ($item in $candSchemes) {
        Assert-True ($byPrefix.ContainsKey($item.Prefix)) "deeplinks.md 候选深链未登记于 deeplinks.json：$($item.Prefix)"
        $entry = $byPrefix[$item.Prefix]
        Assert-True ([string]$entry.expect_package -ceq $item.ExpectPackage) "候选深链 expect_package 不一致：$($item.Prefix)"
        Assert-True ([string]$entry.verified -ceq '') "未实测候选深链不得倒挂标为已验证：$($item.Prefix) (verified=$($entry.verified))"
    }

    Assert-True ($DeeplinksMd -match 'android\.settings\.BLUETOOTH_SETTINGS[^\r\n]*❌') 'deeplinks.md 应保留 BLUETOOTH_SETTINGS ❌ 记录。'
    Assert-True ($DeeplinksMd -match 'android\.settings\.ACCESSIBILITY_SETTINGS[^\r\n]*✅') 'deeplinks.md 应包含 ACCESSIBILITY_SETTINGS ✅ 记录。'

    $unreliable = @($AppsJson.unreliable_settings_actions | ForEach-Object { [string]$_.action })
    Assert-True ('android.settings.BLUETOOTH_SETTINGS' -in $unreliable) 'apps.json unreliable_settings_actions 缺少 BLUETOOTH_SETTINGS。'
    Assert-True ('android.settings.ACCESSIBILITY_SETTINGS' -notin $unreliable) 'ACCESSIBILITY_SETTINGS 已实测可靠，不应列入 unreliable_settings_actions。'

    $nsMgr = [Xml.XmlNamespaceManager]::new($ManifestXml.NameTable)
    $nsMgr.AddNamespace('android', 'http://schemas.android.com/apk/res/android')
    $permNodes = $ManifestXml.SelectNodes('//uses-permission/@android:name', $nsMgr)
    $perms = @($permNodes | ForEach-Object { $_.Value })
    Assert-True ('android.permission.QUERY_ALL_PACKAGES' -notin $perms) 'AndroidManifest.xml 不得包含 QUERY_ALL_PACKAGES。'

    $queriedNodes = $ManifestXml.SelectNodes('//queries/package/@android:name', $nsMgr)
    $queried = @($queriedNodes | ForEach-Object { $_.Value } | Sort-Object -Unique)
    $expectedQueried = @($registeredPackages | Sort-Object -Unique)
    Assert-True (($queried -join ',') -ceq ($expectedQueried -join ',')) 'apps.json aliases 与 AndroidManifest.xml <queries> 不一致。'

    $guideKeys = @($AppsJson.app_guides.PSObject.Properties | ForEach-Object { $_.Name })
    foreach ($reqPkg in @('com.xingin.xhs', 'com.jingdong.app.mall', 'com.taobao.taobao', 'com.android.settings', 'tv.danmaku.bili')) {
        Assert-True ($reqPkg -in $guideKeys) "apps.json app_guides 缺少 $reqPkg。"
    }
    foreach ($gk in $guideKeys) {
        Assert-True ($gk -in $registeredPackages) "apps.json app_guides 键 $gk 未在 aliases 注册。"
    }
}

function Assert-MacroAssetsSync {
    param(
        [Parameter(Mandatory)]$AppsJson,
        [Parameter(Mandatory)]$SafetyJson,
        [Parameter(Mandatory)][string]$MacroDir
    )

    $indexPath = Join-Path $MacroDir 'index.json'
    Assert-True (Test-Path -LiteralPath $indexPath -PathType Leaf) '缺少 assets/skillpack/macros/index.json。'
    $indexJson = Get-Content -LiteralPath $indexPath -Raw -Encoding utf8 | ConvertFrom-Json
    $files = @($indexJson.files)
    Assert-True ($files.Count -ge 1) 'skillpack/macros/index.json files 不得为空。'

    $blockedPrefixes = @($SafetyJson.blocked_app_prefixes)
    $registeredPackages = @()
    foreach ($p in $AppsJson.aliases.PSObject.Properties) { $registeredPackages += [string]$p.Value }
    $allowedTools = @(
        'foreground_app', 'system_get_state', 'skillpack_lookup', 'app_launch', 'open_uri',
        'wait_for', 'ui_snapshot', 'ui_find', 'ui_action', 'type_text', 'press_key'
    )
    $seenIds = @{}

    foreach ($fileName in $files) {
        $macroPath = Join-Path $MacroDir ([string]$fileName)
        Assert-True (Test-Path -LiteralPath $macroPath -PathType Leaf) "宏文件不存在：$fileName"
        $macro = Get-Content -LiteralPath $macroPath -Raw -Encoding utf8 | ConvertFrom-Json
        $id = [string]$macro.id
        Assert-True (-not [string]::IsNullOrWhiteSpace($id)) "宏缺少 id：$fileName"
        Assert-True (-not $seenIds.ContainsKey($id)) "存在重复宏 id：$id"
        $seenIds[$id] = $true

        $pkg = [string]$macro.expect_package
        Assert-True ($pkg -in $registeredPackages) "宏 $id expect_package=$pkg 未在 aliases 注册。"
        foreach ($bp in $blockedPrefixes) {
            Assert-True (-not $pkg.StartsWith([string]$bp, [StringComparison]::Ordinal)) "宏 $id expect_package 命中黑名单：$pkg"
        }
        $ver = [string]$macro.verified
        Assert-True ($ver -ceq '' -or $ver -match '^\d{4}-\d{2}-\d{2}$') "宏 $id verified 格式非法：$ver"

        $steps = @($macro.steps)
        Assert-True ($steps.Count -ge 1) "宏 $id steps 不能为空。"
        $declaredRefSlots = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($step in $steps) {
            $tool = [string]$step.tool
            Assert-True ($tool -in $allowedTools) "宏 $id 步骤 $($step.id) 使用非法/嵌套工具：$tool"
            $argsJson = ($step.args | ConvertTo-Json -Depth 10 -Compress)
            $refSlots = @([regex]::Matches($argsJson, '\{\{\s*ref:([a-zA-Z0-9_]+)\s*\}\}') | ForEach-Object { $_.Groups[1].Value })
            foreach ($slot in $refSlots) {
                Assert-True ($declaredRefSlots.Contains($slot)) "宏 $id 步骤 $($step.id) 引用了未由前序步骤 save_ref 声明的槽位：$slot"
            }
            $skipIfMissingProp = $step.PSObject.Properties['skip_if_ref_missing']
            if ($null -ne $skipIfMissingProp -and [bool]$skipIfMissingProp.Value) {
                Assert-True ($refSlots.Count -ge 1) "宏 $id 步骤 $($step.id) 启用 skip_if_ref_missing 但 args 未引用任何 {{ref:...}} 槽位"
            }
            $saveRefProp = $step.PSObject.Properties['save_ref']
            if ($null -ne $saveRefProp -and -not [string]::IsNullOrWhiteSpace([string]$saveRefProp.Value)) {
                Assert-True ($tool -ceq 'ui_find') "宏 $id 步骤 $($step.id) 仅 ui_find 允许 save_ref"
                [void]$declaredRefSlots.Add(([string]$saveRefProp.Value).Trim())
            }
            if ($tool -ceq 'app_launch') {
                $argNames = @($step.args.PSObject.Properties.Name)
                Assert-True (('name' -in $argNames) -and -not [string]::IsNullOrWhiteSpace([string]$step.args.name) -and ('app' -notin $argNames)) `
                    "宏 $id 步骤 $($step.id) app_launch 必须使用 name 参数"
            }
            if ($id -ceq 'wechat_readonly_prepare') {
                Assert-True ($tool -notin @('ui_action', 'type_text', 'press_key', 'open_uri')) `
                    "宏 $id 严禁包含点击/输入/发送或跳转工具：$tool"
            }
        }
    }
}

$appsPath = Join-Path $repoRoot 'app\gateway\src\main\assets\skillpack\apps.json'
$deeplinksPath = Join-Path $repoRoot 'app\gateway\src\main\assets\skillpack\deeplinks.json'
$safetyPath = Join-Path $repoRoot 'app\gateway\src\main\assets\skillpack\safety.json'
$macroDir = Join-Path $repoRoot 'app\gateway\src\main\assets\skillpack\macros'
$deeplinksMdPath = Join-Path $repoRoot 'docs\knowledge\apps\deeplinks.md'
$manifestPath = Join-Path $repoRoot 'app\gateway\src\main\AndroidManifest.xml'
$readmePath = Join-Path $repoRoot 'docs\knowledge\README.md'
$preamblePath = Join-Path $repoRoot 'scripts\prompts\gateway-executor-preamble.md'
$dispatchPath = Join-Path $repoRoot 'scripts\dispatch.ps1'

Test-Case 'deeplinks_md_and_skillpack_assets_and_manifest_sync' {
    $appsJson = Get-Content -LiteralPath $appsPath -Raw -Encoding utf8 | ConvertFrom-Json
    $deeplinksJson = Get-Content -LiteralPath $deeplinksPath -Raw -Encoding utf8 | ConvertFrom-Json
    $safetyJson = Get-Content -LiteralPath $safetyPath -Raw -Encoding utf8 | ConvertFrom-Json
    $deeplinksMd = Get-Content -LiteralPath $deeplinksMdPath -Raw -Encoding utf8
    [xml]$manifestXml = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8

    Assert-SkillPackSync -AppsJson $appsJson -DeeplinksJson $deeplinksJson -SafetyJson $safetyJson `
        -DeeplinksMd $deeplinksMd -ManifestXml $manifestXml
    Assert-MacroAssetsSync -AppsJson $appsJson -SafetyJson $safetyJson -MacroDir $macroDir

    $macroIndex = Get-Content -LiteralPath (Join-Path $macroDir 'index.json') -Raw -Encoding utf8 | ConvertFrom-Json
    $macroFiles = @($macroIndex.files)
    Assert-True ($macroFiles.Count -eq 7) "skillpack/macros/index.json 应登记 7 个宏，实际为 $($macroFiles.Count)"
    $expectedVerifiedByFile = @{
        'xhs_search_prepare.json'         = '2026-11-25'
        'taobao_readonly_prepare.json'    = '2026-11-25'
        'wechat_readonly_prepare.json'    = '2026-11-25'
        'jd_readonly_prepare.json'        = ''
        'bili_readonly_prepare.json'      = '2026-11-25'
        'bili_readonly_feed_prepare.json' = ''
        'taobao_orders_prepare.json'      = ''
    }
    foreach ($reqFile in @(
        'xhs_search_prepare.json',
        'taobao_readonly_prepare.json',
        'wechat_readonly_prepare.json',
        'jd_readonly_prepare.json',
        'bili_readonly_prepare.json',
        'bili_readonly_feed_prepare.json',
        'taobao_orders_prepare.json'
    )) {
        Assert-True ($reqFile -in $macroFiles) "skillpack/macros/index.json 缺少 $reqFile"
        $macroObj = Get-Content -LiteralPath (Join-Path $macroDir $reqFile) -Raw -Encoding utf8 | ConvertFrom-Json
        $expectedVerified = $expectedVerifiedByFile[$reqFile]
        Assert-True ([string]$macroObj.verified -ceq $expectedVerified) "宏 $reqFile verified 应为 '$expectedVerified'，实际为 '$($macroObj.verified)'"
        Assert-True ($macroObj.readonly -eq $true) "只读前置宏 $reqFile readonly 必须为 true"
    }
}

Test-Case 'knowledge_readme_index_covers_all_app_docs' {
    $readme = Get-Content -LiteralPath $readmePath -Raw -Encoding utf8
    foreach ($rel in @('apps/taobao.md', 'apps/jd.md', 'apps/xiaohongshu.md', 'apps/bilibili.md', 'apps/deeplinks.md')) {
        Assert-True ($readme.Contains($rel, [StringComparison]::Ordinal)) "docs/knowledge/README.md 未索引 $rel"
        $full = Join-Path $repoRoot ("docs\knowledge\" + $rel.Replace('/', '\'))
        Assert-True (Test-Path -LiteralPath $full -PathType Leaf) "索引指向文件不存在：$rel"
    }
}

Test-Case 'preamble_is_device_agnostic_and_tasks_dryrun_clean' {
    $preamble = Get-Content -LiteralPath $preamblePath -Raw -Encoding utf8
    Assert-True ($preamble -notmatch 'vivo X100|OriginOS|PA2553|Android 16|1260[×x]2800|360[×x]800|横屏应用多窗|文件传输助手') `
        'gateway-executor-preamble.md 不得包含设备/ROM 特定词。'
    Assert-True ($preamble.Contains('skillpack_lookup', [StringComparison]::Ordinal)) 'preamble 应引导调用 skillpack_lookup。'
    Assert-True ($preamble.Contains('skill_macro_list', [StringComparison]::Ordinal)) 'preamble 应引导调用 skill_macro_list。'
    Assert-True ($preamble.Contains('skill_macro_exec', [StringComparison]::Ordinal)) 'preamble 应引导调用 skill_macro_exec。'
    Assert-True ($preamble.Contains('system_get_state', [StringComparison]::Ordinal)) 'preamble 应引导优先调用 system_get_state。'
    Assert-True ($preamble.Contains('data.final_snapshot', [StringComparison]::Ordinal)) 'preamble 应明确引导消费 data.final_snapshot。'

    $tasks = @(
        'scripts\tasks\m0-1-bluetooth-off.md',
        'scripts\tasks\check-bluetooth.md',
        'scripts\tasks\m0-3-xhs-summary.md',
        'scripts\tasks\m0-5-jd-order.md',
        'scripts\tasks\taobao-order-readonly.md',
        'scripts\tasks\wechat-readonly-prepare.md',
        'scripts\tasks\bili-readonly-browse.md'
    )
    foreach ($relTask in $tasks) {
        $taskFile = Join-Path $repoRoot $relTask
        Assert-True (Test-Path -LiteralPath $taskFile -PathType Leaf) "缺少任务卡：$relTask"
        $out = & $pwshPath -NoProfile -File $dispatchPath -TaskFile $taskFile -DryRun 2>&1
        $code = $LASTEXITCODE
        $text = ($out | Out-String)
        Assert-True ($code -eq 0) "dispatch DryRun 失败（$relTask, exit=$code）：$text"
        Assert-True ($text.Contains('skillpack_lookup', [StringComparison]::Ordinal)) "DryRun 输出缺少 skillpack_lookup：$relTask"
        Assert-True ($text.Contains('skill_macro_exec', [StringComparison]::Ordinal)) "DryRun 输出缺少 skill_macro_exec：$relTask"
        if ($relTask -ceq 'scripts\tasks\m0-3-xhs-summary.md') {
            Assert-True ($text.Contains('xhs_search_prepare', [StringComparison]::Ordinal)) '小红书任务卡 DryRun 应包含 xhs_search_prepare'
        }
        if ($relTask -ceq 'scripts\tasks\m0-5-jd-order.md') {
            Assert-True ($text.Contains('jd_readonly_prepare', [StringComparison]::Ordinal)) '京东任务卡 DryRun 应包含 jd_readonly_prepare'
        }
        if ($relTask -ceq 'scripts\tasks\taobao-order-readonly.md') {
            Assert-True ($text.Contains('taobao_readonly_prepare', [StringComparison]::Ordinal)) '淘宝只读任务卡 DryRun 应包含 taobao_readonly_prepare'
        }
        if ($relTask -ceq 'scripts\tasks\wechat-readonly-prepare.md') {
            Assert-True ($text.Contains('wechat_readonly_prepare', [StringComparison]::Ordinal)) '微信只读前置任务卡 DryRun 应包含 wechat_readonly_prepare'
        }
        if ($relTask -ceq 'scripts\tasks\bili-readonly-browse.md') {
            Assert-True ($text.Contains('bili_readonly_prepare', [StringComparison]::Ordinal)) '哔哩哔哩只读任务卡 DryRun 应包含 bili_readonly_prepare'
        }
        Assert-True ($text -notmatch '绕过确认卡|自动代登录|自动过验证码|open_uri 打开对应系统设置页') "DryRun 输出命中违禁指引：$relTask"
    }
}

Test-Case 'negative_selftest_rejects_unverified_promotion_duplicates_and_manifest_drift' {
    $appsJson = Get-Content -LiteralPath $appsPath -Raw -Encoding utf8 | ConvertFrom-Json
    $deeplinksJson = Get-Content -LiteralPath $deeplinksPath -Raw -Encoding utf8 | ConvertFrom-Json
    $safetyJson = Get-Content -LiteralPath $safetyPath -Raw -Encoding utf8 | ConvertFrom-Json
    $deeplinksMd = Get-Content -LiteralPath $deeplinksMdPath -Raw -Encoding utf8
    [xml]$manifestXml = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8

    $promoted = $deeplinksJson | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    ($promoted.entries | Where-Object { $_.prefix -ceq 'taobao://' })[0].verified = '2026-11-22'
    Assert-Throws {
        Assert-SkillPackSync -AppsJson $appsJson -DeeplinksJson $promoted -SafetyJson $safetyJson `
            -DeeplinksMd $deeplinksMd -ManifestXml $manifestXml
    } '未实测候选深链不得倒挂'

    $duplicated = $deeplinksJson | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $duplicated.entries += $duplicated.entries[0]
    Assert-Throws {
        Assert-SkillPackSync -AppsJson $appsJson -DeeplinksJson $duplicated -SafetyJson $safetyJson `
            -DeeplinksMd $deeplinksMd -ManifestXml $manifestXml
    } '重复 prefix'

    $badManifest = [xml]((Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8).Replace(
        '<package android:name="com.tmall.wireless" />', ''
    ))
    Assert-Throws {
        Assert-SkillPackSync -AppsJson $appsJson -DeeplinksJson $deeplinksJson -SafetyJson $safetyJson `
            -DeeplinksMd $deeplinksMd -ManifestXml $badManifest
    } 'AndroidManifest\.xml <queries> 不一致'

    $badMacroRoot = Join-Path $repoRoot ('.checks\skillpack-macro-neg-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $badMacroRoot -Force | Out-Null
    try {
        '{"files":["bad.json"]}' | Set-Content -LiteralPath (Join-Path $badMacroRoot 'index.json') -Encoding utf8
        @'
{
  "id": "bad_nested",
  "version": 1,
  "app": "支付宝",
  "expect_package": "com.eg.android.AlipayGphone",
  "description": "invalid",
  "readonly": true,
  "verified": "",
  "params": {},
  "steps": [{"id": "s1", "tool": "skill_macro_exec", "args": {}}]
}
'@ | Set-Content -LiteralPath (Join-Path $badMacroRoot 'bad.json') -Encoding utf8
        Assert-Throws {
            Assert-MacroAssetsSync -AppsJson $appsJson -SafetyJson $safetyJson -MacroDir $badMacroRoot
        } '黑名单|非法/嵌套工具'

        @'
{
  "id": "bad_skip_without_ref",
  "version": 1,
  "app": "淘宝",
  "expect_package": "com.taobao.taobao",
  "description": "invalid skip_if_ref_missing",
  "readonly": true,
  "verified": "",
  "params": {},
  "steps": [{"id": "s1", "tool": "ui_action", "args": {"ref": "e1", "action": "click"}, "skip_if_ref_missing": true}]
}
'@ | Set-Content -LiteralPath (Join-Path $badMacroRoot 'bad.json') -Encoding utf8
        Assert-Throws {
            Assert-MacroAssetsSync -AppsJson $appsJson -SafetyJson $safetyJson -MacroDir $badMacroRoot
        } 'skip_if_ref_missing'
    }
    finally {
        Remove-Item -LiteralPath $badMacroRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "skillpack sync offline: $passed passed, 0 failed"
