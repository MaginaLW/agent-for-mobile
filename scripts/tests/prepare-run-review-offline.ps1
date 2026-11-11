#Requires -Version 7.5
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$tool = Join-Path $root 'scripts/prepare-run-review.ps1'
$pwsh = (Get-Process -Id $PID).Path
$scratch = Join-Path $root ('.checks/reduce-manual-20261111/review-drafts/tests-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $scratch)
$env:TEMP = $scratch; $env:TMP = $scratch
$script:passed = 0; $script:failed = 0
function Assert-Review([bool]$Condition,[string]$Message) { if(-not $Condition){throw $Message} }
function Case([string]$Name,[scriptblock]$Body) {
    try { & $Body; $script:passed++; Write-Host "PASS $Name" }
    catch { $script:failed++; Write-Host "FAIL $Name : $($_.Exception.Message)" }
}
function New-Manifest([string]$Name,[hashtable]$Changes=@{}) {
    $value = [ordered]@{schema='tablet-c1b-run/v2';run_id='offline-review';outcome='passed';exit_code=0;
        commit_sha=('a'*40);producer_commit_sha=('a'*40);apk_sha256=('sha256:'+('b'*64));
        failure_reason=$null; timestamps=@{started_at='2026-11-11T00:00:00Z';finished_at='2026-11-11T00:00:01Z'}}
    foreach($key in $Changes.Keys){$value[$key]=$Changes[$key]}
    $path=Join-Path $scratch ($Name+'.json')
    [IO.File]::WriteAllText($path,($value | ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
    return $path
}
function Invoke-Draft([string]$Name,[string]$Manifest,[string[]]$Extra=@(),[int]$ExpectedExit=0) {
    $directory=Join-Path $scratch $Name
    $lines=@(& $pwsh -NoProfile -File $tool -ManifestPath $Manifest -OutputDirectory $directory @Extra 2>&1)
    if($LASTEXITCODE -ne $ExpectedExit){throw "exit expected $ExpectedExit, got $LASTEXITCODE : $($lines -join ' ')"}
    return $directory
}
$good=New-Manifest 'good'
Case 'historical success preserves unknowns and never authorizes' {
    $out=Invoke-Draft 'success' $good
    $summary=Get-Content -Raw (Join-Path $out 'review.json') | ConvertFrom-Json
    Assert-Review ($summary.historical_outcome -ceq 'passed' -and $summary.ledger_result -ceq 'success') 'historical success lost'
    Assert-Review ($summary.run_authorized -eq $false -and $summary.draft_only -eq $true) 'authorization invented'
    Assert-Review ($summary.outer_exit_code -ceq 'UNKNOWN' -and $summary.cleanup -ceq 'UNKNOWN') 'missing exit/cleanup filled'
    Assert-Review ($summary.current_scope.device_evidence -ceq 'UNKNOWN') 'historical device substituted'
    Assert-Review ((Get-ChildItem -LiteralPath $out -File).Count -eq 5) 'five artifacts missing'
}
Case 'failure manifest v1 keeps exact reason and nonzero runner exit' {
    $path=New-Manifest 'failure' @{schema='tablet-c1b-run/v1';outcome='failed';exit_code=1;failure_reason='T0 absent/session_not_found'}
    $out=Invoke-Draft 'failure-out' $path
    $summary=Get-Content -Raw (Join-Path $out 'review.json') | ConvertFrom-Json
    Assert-Review ($summary.ledger_result -ceq 'fail' -and $summary.runner_exit_code -eq 1) 'failure promoted'
    Assert-Review ($summary.failure_reason -ceq 'T0 absent/session_not_found') 'failure precision lost'
}
Case 'inconsistent success and exit cannot become ledger success' {
    $out=Invoke-Draft 'inconsistent-out' (New-Manifest 'inconsistent' @{exit_code=1})
    $summary=Get-Content -Raw (Join-Path $out 'review.json') | ConvertFrom-Json
    Assert-Review ($summary.ledger_result -ceq 'UNKNOWN') 'inconsistent evidence accepted'
}
Case 'explicit commit mismatch blocks with diagnostic artifacts' {
    $out=Invoke-Draft 'bad-commit' $good @('-ExpectedCommitSha',('c'*40)) 2
    $summary=Get-Content -Raw (Join-Path $out 'review.json') | ConvertFrom-Json
    Assert-Review ($summary.identity_status -ceq 'blocked' -and $summary.run_authorized -eq $false) 'mismatch not blocked'
}
Case 'APK bytes are hashed and matched to manifest and expected hash' {
    $apk=Join-Path $scratch 'offline.apk'; [IO.File]::WriteAllBytes($apk,[byte[]](1,2,3,4))
    $hash=(Get-FileHash -LiteralPath $apk).Hash
    $path=New-Manifest 'apk-good' @{apk_sha256=('sha256:'+$hash.ToLowerInvariant())}
    $out=Invoke-Draft 'apk-good-out' $path @('-ApkPath',$apk,'-ExpectedApkSha256',$hash,'-ExpectedCommitSha',('a'*40))
    $summary=Get-Content -Raw (Join-Path $out 'review.json') | ConvertFrom-Json
    Assert-Review ($summary.identity_status -ceq 'matched' -and $summary.actual_apk_sha256 -ieq $hash) 'APK hash not matched'
    Assert-Review ($summary.certificate_sha256 -ceq 'UNKNOWN') 'certificate guessed'
}
Case 'supplied expected APK without bytes remains blocked' {
    [void](Invoke-Draft 'apk-missing' $good @('-ExpectedApkSha256',('b'*64)) 2)
}
Case 'manifest APK hash mismatch blocks even without explicit expectation' {
    [void](Invoke-Draft 'apk-bad' $good @('-ApkPath',(Join-Path $scratch 'offline.apk')) 2)
}
Case 'public certificate expectation without verifier is blocked' {
    [void](Invoke-Draft 'cert-missing' $good @('-ExpectedCertificateSha256',('c'*64)) 2)
}
Case 'public signer identity is verified from supplied APK without a keystore' {
    $dir=Join-Path $scratch 'public-signer'; [void](New-Item -ItemType Directory -Path $dir)
    $signer=Join-Path $dir 'apksigner.bat'
    [IO.File]::WriteAllText($signer,"@echo off`r`necho Signer #1 certificate SHA-256 digest: $('c'*64)`r`nexit /b 0`r`n")
    $hash=(Get-FileHash -LiteralPath (Join-Path $scratch 'offline.apk')).Hash
    $path=New-Manifest 'cert-good' @{apk_sha256=('sha256:'+$hash.ToLowerInvariant())}
    $out=Invoke-Draft 'cert-good-out' $path @('-ApkPath',(Join-Path $scratch 'offline.apk'),'-ApkSignerPath',$signer,'-ExpectedCertificateSha256',('c'*64))
    $summary=Get-Content -Raw (Join-Path $out 'review.json') | ConvertFrom-Json
    Assert-Review ($summary.identity_status -ceq 'matched' -and $summary.certificate_sha256 -ceq ('c'*64)) 'public signer extraction failed'
}
Case 'multiple signers do not silently select the first certificate' {
    $signer=Join-Path $scratch 'public-signer/apksigner.bat'
    [IO.File]::WriteAllText($signer,"@echo off`r`necho Signer #1 certificate SHA-256 digest: $('c'*64)`r`necho Signer #2 certificate SHA-256 digest: $('d'*64)`r`nexit /b 0`r`n")
    [void](Invoke-Draft 'cert-ambiguous' (Join-Path $scratch 'cert-good.json') @('-ApkPath',(Join-Path $scratch 'offline.apk'),'-ApkSignerPath',$signer) 2)
}
Case 'invalid APK signature blocks public identity preflight' {
    $signer=Join-Path $scratch 'public-signer/apksigner.bat'
    [IO.File]::WriteAllText($signer,"@echo off`r`nexit /b 1`r`n")
    [void](Invoke-Draft 'cert-invalid' (Join-Path $scratch 'cert-good.json') @('-ApkPath',(Join-Path $scratch 'offline.apk'),'-ApkSignerPath',$signer) 2)
}
Case 'boolean exit code cannot masquerade as integer zero' {
    $out=Invoke-Draft 'boolean-out' (New-Manifest 'boolean' @{exit_code=$false})
    $summary=Get-Content -Raw (Join-Path $out 'review.json') | ConvertFrom-Json
    Assert-Review ($summary.ledger_result -ceq 'UNKNOWN') 'boolean exit became success'
}
Case 'array outcome cannot masquerade as scalar passed' {
    [void](Invoke-Draft 'array-outcome-out' (New-Manifest 'array-outcome' @{outcome=@('passed')}) @() 1)
}
Case 'explicit scope fills report and ask while retaining no authorization' {
    $scope=[ordered]@{schema='run-review-scope/v1';request_id='A01';device_evidence='待本轮核对';pose_evidence='横屏';
        windows_evidence='现场双窗';ime_evidence='现场隐藏';stages=@('身份核验','一次条件采集');max_sdk_calls=12;
        read_budget_seconds=140;activation='现场明确批准且前置通过后一次激活';latest_activation='2026-11-11 23:00 Asia/Singapore';stop_conditions=@('任一阶段失败即冻结')}
    $path=Join-Path $scratch 'scope.json'; $scope | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding utf8
    $out=Invoke-Draft 'scope-out' $good @('-ScopePath',$path)
    $summary=Get-Content -Raw (Join-Path $out 'review.json') | ConvertFrom-Json
    Assert-Review ($summary.current_scope.max_sdk_calls -eq 12 -and $summary.run_authorized -eq $false) 'scope changed authority'
    $ask=Get-Content -Raw (Join-Path $out 'ask.md')
    Assert-Review ($ask.Contains('0不用问不单报／1结果告知／2需要选择／3逐次确认') -and $ask.Contains('A01')) 'ask format missing'
}
Case 'CSV uses existing 17-column contract and neutralizes formulas' {
    $out=Invoke-Draft 'csv-out' (New-Manifest 'csv' @{run_id='=1+1';failure_reason='line1,"quoted"'+"`n"+'line2'})
    . (Join-Path $root 'scripts/lib/dispatch-ledger.ps1')
    $path=Join-Path $out 'ledger-draft.csv'
    [void](Assert-P0LedgerCsvContract -Bytes ([IO.File]::ReadAllBytes($path)) -LedgerPath $path)
    $row=Import-Csv -LiteralPath $path
    Assert-Review ($row.slug -ceq "'=1+1" -and $row.cost_usd -ceq 'UNKNOWN' -and $row.leg -ceq 'UNKNOWN') 'CSV corrupted or zero-filled'
}
Case 'unsupported manifest schema is rejected before output' {
    [void](Invoke-Draft 'unsupported-out' (New-Manifest 'unsupported' @{schema='invented/v1'}) @() 1)
    Assert-Review (-not(Test-Path -LiteralPath (Join-Path $scratch 'unsupported-out'))) 'unsupported manifest wrote drafts'
}
Case 'duplicate JSON keys rejected rather than last-key wins' {
    $path=Join-Path $scratch 'duplicate.json'; [IO.File]::WriteAllText($path,'{"schema":"tablet-c1b-run/v2","outcome":"passed","outcome":"failed"}')
    [void](Invoke-Draft 'duplicate-out' $path @() 1)
}
Case 'output outside ignored area is rejected' {
    $lines=@(& $pwsh -NoProfile -File $tool -ManifestPath $good -OutputDirectory (Join-Path $root 'docs/runs/review-should-not-exist') 2>&1)
    Assert-Review ($LASTEXITCODE -ne 0) 'tracked output allowed'
    Assert-Review (-not(Test-Path -LiteralPath (Join-Path $root 'docs/runs/review-should-not-exist'))) 'outside file created'
}
Case 'existing draft cannot be silently overwritten' {
    [void](Invoke-Draft 'success' $good @() 1)
}
Write-Host "prepare run review offline: $script:passed passed, $script:failed failed"
if($script:failed){exit 1}
