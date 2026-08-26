#Requires -Version 7.5
<# T-L1 C1a 无设备 gate：只运行 AST、schema 与 fake adb/content/gradle/apksigner 套件。 #>
[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
Set-StrictMode -Version 3.0
[Console]::OutputEncoding=[Text.Encoding]::UTF8
$OutputEncoding=[Text.Encoding]::UTF8

$RepoRoot=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
$Checks=Join-Path $RepoRoot '.checks'
$SuitePath=Join-Path $PSScriptRoot 'tests\tablet-layout-c1a-offline.ps1'
$SuiteSummaryPath=Join-Path $Checks 'tablet-layout-c1a-offline-suite-summary.json'
$GateSummaryPath=Join-Path $Checks 'tablet-layout-c1a-offline-gate.summary.json'
$LogPath=Join-Path $Checks 'tablet-layout-c1a-offline.log'
$PwshPath=(Get-Process -Id $PID).Path
$Required=[string[]]@(
    'entry_absolute_adb', 'entry_full_sha', 'entry_explicit_provision', 'head_clean_exact',
    'clean_port_blob_attest', 'fresh_build_challenge', 'gradle_kotlin_cache_ignored', 'single_device', 'post_discovery_serial',
    'install_once_no_retry', 'apk_hash_binding', 'apksigner_certificate', 'package_version_binding',
    'embedded_head_challenge', 'a11y_needs_user_no_mutation', 'content_protocol_exact',
    'content_nonce_constant', 'title_hash_exact', 't0_raw_bytes_unchanged', 'capture_exact_c1_c2',
    'capture_host_wait_900', 'capture_span_15s', 'no_recapture', 'result_single_consume',
    'abort_cleanup', 'device_binding_pre_post', 'safe_atomic_evidence', 'trusted_runtime_validator',
    'public_runtime_unavailable', 'claim_scope_false', 'privacy_no_raw_secret', 'argv_allowlist',
    'content_remote_shell_literal', 'content_t0_binary_stdin', 'content_stderr_empty', 'stdin_overall_deadline',
    'installed_host_stream_pre_post', 'installed_stderr_cap_after_eof', 'installed_path_closed', 'post_apk_binding',
    'control_json_types_exact', 'a11y_bound_wait_vivo', 'implementation_hash_postcheck',
    'published_evidence_postcheck', 't0_sidecar_stderr_empty', 'release_absence_gate'
)

function Assert-ChecksDirectory {
    if(Test-Path -LiteralPath $Checks){
        $item=Get-Item -LiteralPath $Checks -Force
        if(-not $item.PSIsContainer -or ($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw '.checks 不是普通目录。'}
    }else{New-Item -ItemType Directory -Path $Checks|Out-Null}
}

function Test-C1aSuiteSummary {
    param([Parameter(Mandatory)]$Summary)
    $fields='schema_version,suite,generated_at_utc,status,device_access,selected,passed,failed,required_coverage,cases'
    if(($Summary.PSObject.Properties.Name-join',')-cne $fields){throw 'suite summary 字段漂移。'}
    if([long]$Summary.schema_version-ne1-or$Summary.suite-cne'tablet_layout_c1a_offline'-or
        $Summary.device_access-cne'fake_tools_only'-or$Summary.status-cne'passed'){throw 'suite summary 常量错误。'}
    $cases=@($Summary.cases);$selected=[long]$Summary.selected
    $passed=@($cases|Where-Object{$_.status-ceq'passed'}).Count;$failed=@($cases|Where-Object{$_.status-ceq'failed'}).Count
    if($selected-le0-or$selected-ne$cases.Count-or[long]$Summary.passed-ne$passed-or
        [long]$Summary.failed-ne$failed-or$failed-ne0-or$selected-ne($passed+$failed)){throw 'suite summary 计数伪造或 0 case。'}
    $caseNames=[string[]]@($cases|ForEach-Object{[string]$_.name})
    if(@($caseNames|Select-Object -Unique).Count-ne$caseNames.Count){throw 'suite case 名重复。'}
    $coverage=@($Summary.required_coverage)
    if($coverage.Count-ne$Required.Count){throw 'coverage 数量漂移。'}
    $ids=[string[]]@($coverage|ForEach-Object{[string]$_.id})
    if(@($ids|Select-Object -Unique).Count-ne$ids.Count){throw 'coverage ID 重复。'}
    $actualSorted=[string[]]@($ids);$requiredSorted=[string[]]@($Required)
    [Array]::Sort($actualSorted,[StringComparer]::Ordinal);[Array]::Sort($requiredSorted,[StringComparer]::Ordinal)
    if(($actualSorted-join"`n")-cne($requiredSorted-join"`n")){throw 'coverage ID 缺失或额外。'}
    foreach($entry in $coverage){
        if($entry.status-cne'passed'-or@($entry.cases).Count-eq0){throw "coverage 未通过：$($entry.id)。"}
        $actualCases=@($cases|Where-Object{@($_.covers)-contains$entry.id}|ForEach-Object{$_.name})
        if((@($entry.cases)-join"`n")-cne($actualCases-join"`n")){throw "coverage 映射自报不一致：$($entry.id)。"}
    }
    foreach($case in $cases){
        foreach($id in @($case.covers)){if($Required-cnotcontains$id){throw "case 覆盖未知 ID：$id。"}}
    }
}

Assert-ChecksDirectory
foreach($stale in @($SuiteSummaryPath,$GateSummaryPath,$LogPath)){
    if(Test-Path -LiteralPath $stale){Remove-Item -LiteralPath $stale -Force}
}
$astFiles=@(
    (Join-Path $PSScriptRoot 'lib\tablet-layout-c1a.ps1'),
    (Join-Path $PSScriptRoot 'lib\tablet-layout-c1a-t0-adb-sidecar.ps1'),
    (Join-Path $PSScriptRoot 'lib\tablet-layout-observation-v2-validator.ps1'),
    (Join-Path $PSScriptRoot 'run-tablet-layout-c1a.ps1'),$SuitePath,$PSCommandPath,
    (Join-Path $PSScriptRoot 'check.ps1')
)
foreach($file in $astFiles){
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($file,[ref]$tokens,[ref]$errors)
    if(@($errors).Count-gt0){throw "PowerShell AST 失败：$(Split-Path $file -Leaf)。"}
}
$sidecarSchema=Join-Path $RepoRoot 'docs\contracts\tablet-layout-c1a-sidecar-v1.schema.json'
try{Get-Content -LiteralPath $sidecarSchema -Raw -Encoding utf8|ConvertFrom-Json -Depth 100|Out-Null}catch{throw 'C1a sidecar schema 不是合法 JSON。'}
$start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$PwshPath;$start.WorkingDirectory=$RepoRoot
$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardInput=$true
$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
foreach($arg in @('-NoProfile','-File',$SuitePath,'-SummaryPath',$SuiteSummaryPath)){$start.ArgumentList.Add($arg)}
$process=[Diagnostics.Process]::new();$process.StartInfo=$start
try{
    if(-not$process.Start()){throw '无法启动 C1a offline suite。'};$process.StandardInput.Close()
    $out=$process.StandardOutput.ReadToEndAsync();$err=$process.StandardError.ReadToEndAsync()
    if(-not$process.WaitForExit(180000)){$process.Kill($true);[void]$process.WaitForExit(5000);throw 'C1a offline suite 超时。'}
    $exit=$process.ExitCode;$log=$out.GetAwaiter().GetResult()+$err.GetAwaiter().GetResult()
}finally{$process.Dispose()}
Set-Content -LiteralPath $LogPath -Value $log -Encoding utf8NoBOM
if($exit-ne0-or-not(Test-Path -LiteralPath $SuiteSummaryPath -PathType Leaf)){throw 'C1a offline suite 失败。'}
$summary=Get-Content -LiteralPath $SuiteSummaryPath -Raw -Encoding utf8|ConvertFrom-Json -Depth 30
Test-C1aSuiteSummary $summary

# gate 自证三类反欺骗：0 case、重复 coverage、假安全提升都必须被拒绝。
$selfPassed=0
$zero=$summary|ConvertTo-Json -Depth 30|ConvertFrom-Json -Depth 30;$zero.selected=0;$zero.passed=0;$zero.cases=@()
try{Test-C1aSuiteSummary $zero;throw 'zero case 未被拒绝'}catch{if($_.Exception.Message-cne'zero case 未被拒绝'){$selfPassed++}else{throw}}
$duplicate=$summary|ConvertTo-Json -Depth 30|ConvertFrom-Json -Depth 30
$duplicate.required_coverage[1].id=$duplicate.required_coverage[0].id
try{Test-C1aSuiteSummary $duplicate;throw '重复 coverage 未被拒绝'}catch{if($_.Exception.Message-cne'重复 coverage 未被拒绝'){$selfPassed++}else{throw}}
$schemaRaw=Get-Content -LiteralPath $sidecarSchema -Raw
if($schemaRaw-match '"runtime_evidence"\s*:\s*\{\s*"const"\s*:\s*false' -and
    $schemaRaw-match '"execution_grant"\s*:\s*\{\s*"const"\s*:\s*false'){$selfPassed++}
if($selfPassed-ne3){throw 'C1a gate self-test 未全过。'}

$gate=[ordered]@{
    schema_version=1;gate='tablet_layout_c1a_offline_gate';run_id=('c1a-gate-'+[guid]::NewGuid().ToString('N'))
    generated_at_utc=[DateTime]::UtcNow.ToString('o');status='passed';device_access='none_fake_only'
    cases=[long]$summary.selected;passed=[long]$summary.passed;required_coverage=$Required.Count
    coverage_passed=$Required.Count;self_tests_passed=$selfPassed
    runtime_evidence=$false;layout_accepted=$false;wechat_layout_verified=$false
    editor_action_ready=$false;p0_capability='unsupported';execution_grant=$false
}
$temporary=Join-Path $Checks ('.tablet-layout-c1a-gate-'+[guid]::NewGuid().ToString('N')+'.tmp')
try{
    $gateJson=$gate|ConvertTo-Json -Depth 8 -Compress
    $gateBytes=[Text.UTF8Encoding]::new($false).GetBytes($gateJson)
    [IO.File]::WriteAllBytes($temporary,$gateBytes)
    Move-Item -LiteralPath $temporary -Destination $GateSummaryPath
    $publishedBytes=[IO.File]::ReadAllBytes($GateSummaryPath)
    if((Get-FileHash -Algorithm SHA256 -LiteralPath $GateSummaryPath).Hash -cne
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($gateBytes))){throw 'gate summary 发布后 hash 漂移。'}
    $published=[Text.UTF8Encoding]::new($false,$true).GetString($publishedBytes)|ConvertFrom-Json -Depth 20
    $expectedFields='schema_version,gate,run_id,generated_at_utc,status,device_access,cases,passed,required_coverage,coverage_passed,self_tests_passed,runtime_evidence,layout_accepted,wechat_layout_verified,editor_action_ready,p0_capability,execution_grant'
    if(($published.PSObject.Properties.Name-join',')-cne$expectedFields-or
        $published.run_id-cne$gate.run_id-or$published.status-cne'passed'-or
        $published.runtime_evidence-ne$false-or$published.execution_grant-ne$false){throw 'gate summary 写后读回复核失败。'}
}
finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}}
Write-Host "tablet T-L1 C1a offline gate：$($gate.passed)/$($gate.cases) cases，$($gate.coverage_passed)/$($gate.required_coverage) coverage，self=$selfPassed/3"
