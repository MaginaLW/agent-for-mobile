#Requires -Version 7.5
<#
从既有 C1b run manifest 生成离线复核草稿。只读输入，不读设备、私钥或写真实台账。
所有输出限仓库 .checks/；产物不是开跑令，也不把历史身份当作当前就位。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ManifestPath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$ScopePath,
    [string]$ApkPath,
    [string]$ApkSignerPath,
    [ValidatePattern('^$|^[0-9a-fA-F]{40}$')][string]$ExpectedCommitSha,
    [ValidatePattern('^$|^(sha256:)?[0-9a-fA-F]{64}$')][string]$ExpectedApkSha256,
    [ValidatePattern('^$|^[0-9a-fA-F]{64}$')][string]$ExpectedCertificateSha256
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'lib/dispatch-ledger.ps1')
$encoding = [Text.UTF8Encoding]::new($false, $true)

function Read-ReviewJson([string]$Path) {
    $raw = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).Path, $encoding)
    $document = [Text.Json.JsonDocument]::Parse($raw)
    function Assert-UniqueKeys([Text.Json.JsonElement]$Element) {
        if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
            $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($property in $Element.EnumerateObject()) {
                if (-not $names.Add($property.Name)) { throw '输入 JSON 字段重复。' }
                Assert-UniqueKeys $property.Value
            }
        } elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
            foreach ($item in $Element.EnumerateArray()) { Assert-UniqueKeys $item }
        }
    }
    try {
        if ($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) { throw '输入须为 JSON 对象。' }
        Assert-UniqueKeys $document.RootElement
        return ConvertFrom-Json -InputObject $raw -AsHashtable -Depth 100 -DateKind String
    } finally { $document.Dispose() }
}
function Value-OrUnknown($Map, [string]$Key) {
    if ($Map -is [Collections.IDictionary] -and $Map.Contains($Key) -and $null -ne $Map[$Key] -and
        -not [string]::IsNullOrWhiteSpace([string]$Map[$Key])) { return ,$Map[$Key] }
    return 'UNKNOWN'
}
function Normalize-ReviewHash([string]$Hash) { return ($Hash -replace '^sha256:', '').ToLowerInvariant() }
function Markdown-ReviewValue($Value) {
    if ($Value -is [array]) { $Value = $Value -join '；' }
    return [string]$Value -replace '[\r\n]+', ' / ' -replace '\|', '\|' -replace '`', '\`'
}

$output = [IO.Path]::GetFullPath($OutputDirectory)
$allowed = [IO.Path]::GetFullPath((Join-Path $root '.checks')) + [IO.Path]::DirectorySeparatorChar
if (-not $output.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) {
    throw '草稿输出必须位于本仓库 .checks/ 的子目录，禁止覆盖真实台账或源码。'
}
$ancestor = $output
while ($ancestor.Length -ge $allowed.TrimEnd([IO.Path]::DirectorySeparatorChar).Length) {
    if (Test-Path -LiteralPath $ancestor) {
        if ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw '草稿输出路径不得经过链接或 junction。'
        }
    }
    $ancestor = [IO.Path]::GetDirectoryName($ancestor)
}
$names = @('review.json', 'readiness.md', 'ask.md', 'ledger-draft.csv', 'run-draft.md')
foreach ($name in $names) {
    if (Test-Path -LiteralPath (Join-Path $output $name)) { throw '草稿已存在，拒绝覆盖。' }
}
$manifest = Read-ReviewJson $ManifestPath
foreach ($field in @('schema','run_id','outcome','commit_sha','producer_commit_sha','apk_sha256','failure_reason')) {
    if ($manifest.Contains($field) -and $null -ne $manifest[$field] -and $manifest[$field] -isnot [string]) {
        throw 'manifest 标量字段类型错误。'
    }
}
if ((Value-OrUnknown $manifest 'schema') -cnotin @('tablet-c1b-run/v1', 'tablet-c1b-run/v2')) {
    throw '仅接受既有 tablet-c1b-run/v1 或 v2 manifest。'
}
$scope = if ($ScopePath) { Read-ReviewJson $ScopePath } else { @{} }
if ($ScopePath -and (Value-OrUnknown $scope 'schema') -cne 'run-review-scope/v1') { throw '范围文件 schema 不匹配。' }
$issues = [Collections.Generic.List[string]]::new()
$checks = [Collections.Generic.List[string]]::new()
$commit = Value-OrUnknown $manifest 'commit_sha'
$apkHash = Value-OrUnknown $manifest 'apk_sha256'
$actualApkHash = 'UNKNOWN'
$certificate = 'UNKNOWN'
if ($ExpectedCommitSha) {
    $checks.Add('commit_sha')
    if ($commit -ieq 'UNKNOWN' -or $commit -ine $ExpectedCommitSha) { $issues.Add('commit_sha_mismatch_or_missing') }
}
if ($ApkPath) {
    $actualApkHash = (Get-FileHash -LiteralPath $ApkPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($apkHash -ieq 'UNKNOWN' -or (Normalize-ReviewHash $apkHash) -cne $actualApkHash) {
        $issues.Add('manifest_apk_sha256_mismatch_or_missing')
    }
}
if ($ExpectedApkSha256) {
    $checks.Add('apk_sha256')
    $expected = Normalize-ReviewHash $ExpectedApkSha256
    if ($actualApkHash -ceq 'UNKNOWN' -or $actualApkHash -cne $expected) { $issues.Add('apk_sha256_mismatch_or_missing') }
}
if ($ApkSignerPath -and -not $ApkPath) { throw '公开签名验证需要显式 APK。' }
if ($ApkSignerPath) {
    $signer = (Resolve-Path -LiteralPath $ApkSignerPath).Path
    if ([IO.Path]::GetFileName($signer) -cnotin @('apksigner', 'apksigner.bat', 'apksigner.exe')) {
        throw '签名验证入口须为显式 apksigner。'
    }
    $signerOutput = @(& $signer verify --print-certs (Resolve-Path -LiteralPath $ApkPath).Path 2>&1)
    if ($LASTEXITCODE -ne 0) { $issues.Add('apk_signature_invalid') }
    else {
        $matches = @([regex]::Matches(($signerOutput -join "`n"), '(?m)^Signer #\d+ certificate SHA-256 digest: ([0-9a-fA-F]{64})\s*$'))
        if ($matches.Count -ne 1) { $issues.Add('apk_signer_identity_ambiguous') }
        else { $certificate = $matches[0].Groups[1].Value.ToLowerInvariant() }
    }
}
if ($ExpectedCertificateSha256) {
    $checks.Add('certificate_sha256')
    if ($certificate -ceq 'UNKNOWN' -or $certificate -ine $ExpectedCertificateSha256) {
        $issues.Add('certificate_sha256_mismatch_or_missing')
    }
}
$identity = if ($issues.Count) { 'blocked' } elseif ($checks.Count) { 'matched' } else { 'not_checked' }
$timestamps = Value-OrUnknown $manifest 'timestamps'
$scopeFields = @('request_id','device_evidence','pose_evidence','windows_evidence','ime_evidence',
    'stages','max_sdk_calls','read_budget_seconds','activation','latest_activation','stop_conditions')
$scopeSummary = [ordered]@{}
foreach ($field in $scopeFields) { $scopeSummary[$field] = Value-OrUnknown $scope $field }
foreach ($field in @('max_sdk_calls','read_budget_seconds')) {
    if ($scopeSummary[$field] -cne 'UNKNOWN' -and ($scopeSummary[$field] -isnot [long] -and $scopeSummary[$field] -isnot [int] -or $scopeSummary[$field] -le 0)) {
        throw '范围累计次数与读取预算必须为正整数。'
    }
}
foreach ($field in @('stages','stop_conditions')) {
    if ($scopeSummary[$field] -cne 'UNKNOWN' -and ($scopeSummary[$field] -isnot [array] -or $scopeSummary[$field].Count -eq 0)) {
        throw '阶段与停止条件必须为非空字符串数组。'
    }
    if ($scopeSummary[$field] -is [array]) {
        foreach ($item in $scopeSummary[$field]) {
            if ($item -isnot [string] -or [string]::IsNullOrWhiteSpace($item)) { throw '阶段与停止条件必须为非空字符串数组。' }
        }
    }
}
$outcome = Value-OrUnknown $manifest 'outcome'
$exitCode = Value-OrUnknown $manifest 'exit_code'
$runId = Value-OrUnknown $manifest 'run_id'
$cleanup = Value-OrUnknown $manifest 'cleanup'
$failure = Value-OrUnknown $manifest 'failure_reason'
$integerExit = $exitCode -is [long] -or $exitCode -is [int]
$result = if ($outcome -ceq 'passed' -and $integerExit -and $exitCode -eq 0) { 'success' }
    elseif ($outcome -ceq 'failed' -and $integerExit -and $exitCode -ne 0) { 'fail' }
    else { 'UNKNOWN' }
$summary = [ordered]@{
    schema='run-review-draft/v1'; draft_only=$true; run_authorized=$false
    source_manifest_sha256=(Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    source_schema=$manifest.schema; run_id=$runId; commit_sha=$commit
    producer_commit_sha=(Value-OrUnknown $manifest 'producer_commit_sha')
    manifest_apk_sha256=$apkHash; actual_apk_sha256=$actualApkHash; certificate_sha256=$certificate
    identity_status=$identity; checked_expectations=$checks.ToArray(); identity_issues=$issues.ToArray()
    historical_outcome=$outcome; runner_exit_code=$exitCode; outer_exit_code='UNKNOWN'
    ledger_result=$result; failure_reason=$failure; cleanup=$cleanup
    started_at=(Value-OrUnknown $timestamps 'started_at'); finished_at=(Value-OrUnknown $timestamps 'finished_at')
    current_scope=$scopeSummary
}
$common = @(
    '> 离线草稿：仅汇总历史证据；未获运行许可，不证明当前现场、持续绑定或清理成功。',
    '', ('- 原 manifest SHA-256：`'+$summary.source_manifest_sha256+'`'),
    ('- 历史 run：'+(Markdown-ReviewValue $runId)), ('- 固定代码 SHA：'+(Markdown-ReviewValue $commit)),
    ('- producer SHA：'+(Markdown-ReviewValue $summary.producer_commit_sha)),
    ('- APK manifest / 实读 SHA：'+(Markdown-ReviewValue $apkHash)+' / '+$actualApkHash),
    ('- 公开签名证书 SHA：'+$certificate),
    ('- 身份预检（仅对应下列已检查项，不代表整体就绪）：'+$identity),
    ('- 显式期望检查项：'+($(if($checks.Count){$checks -join '；'}else{'未检查'}))),
    ('- 身份问题：'+($(if($issues.Count){$issues -join '；'}else{'无显式失配；未检查项仍为 UNKNOWN'}))),
    ('- 历史 outcome / runner exit：'+(Markdown-ReviewValue $outcome)+' / '+(Markdown-ReviewValue $exitCode)),
    '- 外层退出码：UNKNOWN（不从 runner 推断）', ('- cleanup：'+(Markdown-ReviewValue $cleanup)),
    ('- failure_reason：'+(Markdown-ReviewValue $failure))
)
$scopeLines = foreach ($field in $scopeFields) { '- '+$field+'：'+(Markdown-ReviewValue $scopeSummary[$field]) }
$readiness = @('# 就位复核草稿', '') + $common + @('', '## 本轮范围（待 A 核对；历史 manifest 不能填充当前就位）', '') + $scopeLines
$ask = @('# 执行确认草稿（未发送）', '', '仅在未知字段补齐、身份和现场核对通过且确需新许可时，由 A 发出。已有许可覆盖的阶段连续执行，不逐阶段重复询问。', '') + $common + @('', '## 本轮阶段与累计预算', '') + $scopeLines + @(
    '', '批准仅覆盖上述固定对象、阶段与累计预算；失败即冻结，不自动重试。安装等待不自动超时，且不计入读取预算；危险动作仍须现场设备端可见确认卡。',
    '', '编号：'+(Markdown-ReviewValue $scopeSummary.request_id)+'。可回复「批准」或「批准；1分」；评分可省略。0不用问不单报／1结果告知／2需要选择／3逐次确认；评分不授予以后权限。'
)
$runDraft = @('# 运行记录草稿', '') + $common + @('', '## 判读与待补', '',
    '- 历史合同成功不等于 T-L1、P0 或 execution 通过。',
    '- 当前设备/姿态/窗口/IME 证据及阶段预算由就位复核草稿显式列出；UNKNOWN 不作通过。',
    '- 模型、token、成本、总耗时、外层退出码及未记录 cleanup 均为 UNKNOWN，不补零。',
    '- 本工具未安装、签名、操作设备、写真实台账、发送确认或执行任何运行。')
$ledgerValues = @($summary.finished_at,$runId,'UNKNOWN','UNKNOWN','UNKNOWN','UNKNOWN','UNKNOWN','UNKNOWN','UNKNOWN','UNKNOWN',
    'UNKNOWN','UNKNOWN',$result,'UNKNOWN','UNKNOWN',('DRAFT_ONLY;source_manifest_sha256='+$summary.source_manifest_sha256),$failure)
$csv = $P0LedgerHeader+"`n"+(($ledgerValues | ForEach-Object { ConvertTo-P0CsvField $_ }) -join ',')+"`n"
[void](New-Item -ItemType Directory -Path $output -Force)
[IO.File]::WriteAllText((Join-Path $output 'review.json'), ($summary | ConvertTo-Json -Depth 20)+"`n", $encoding)
foreach ($entry in @(@('readiness.md',$readiness),@('ask.md',$ask),@('run-draft.md',$runDraft))) {
    [IO.File]::WriteAllText((Join-Path $output $entry[0]), ($entry[1] -join "`n")+"`n", $encoding)
}
[IO.File]::WriteAllText((Join-Path $output 'ledger-draft.csv'), $csv, $encoding)
Write-Host ('run review draft: identity='+$identity+'; source='+$summary.source_manifest_sha256+'; authorized=false')
if ($issues.Count) { exit 2 }
