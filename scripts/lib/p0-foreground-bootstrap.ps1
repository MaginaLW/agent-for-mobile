#Requires -Version 7
<#
冷启动自举检查的纯判据。

**为什么单独成册**：2026-08-01 批次 1 验收里，自举分支三次 `-Provision` 都没被触达
（trace 里 `bootstrap` 零次出现），判据记为"未触达"——既不是通过也不是失败。
把"读到什么算触达、算通过、算没复现"写成纯函数，是为了让这三种结局在离线用例里**分得开**：
**"场景没复现"必须有自己的名字，绝不能落进"通过"**。这正是上一轮栽的地方。

判据的输入是 `foreground_app`（R 级只读工具）的 data 段：
`foreground_known` / `foreground_identity_source` / `activity` / `tracked_identity.bootstrapped`。
#>

# 刻意不写 Set-StrictMode：本册被别的脚本 dot-source，而 dot-source 的 StrictMode 会作用到
# 调用方整个脚本作用域（同 dispatch-pause.ps1 的理由）。

<# 旧 APK 不报新字段；读不存在的属性在 StrictMode 下是硬错误，必须先探再读。 #>
function Get-P0ForegroundProperty {
    param([Parameter(Mandatory)][AllowNull()]$Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

<#
把一次 `foreground_app` 读数归成一个身份来源。

四种结局，**必须互相分得开**：
- `bootstrap`  身份由冷启动自举建立（package 级、无 activity）
- `event`      身份由窗口状态事件建立（完整 package + activity）
- `unset`      身份尚未建立（`foreground_known=false`）——自举**没生效**
- `unknown`    读不出来（旧 APK 不报该字段 / 响应异常）——不是通过也不是失败
#>
function Get-P0ForegroundIdentityKind {
    param([Parameter(Mandatory)][AllowNull()]$Data)

    if ($null -eq $Data) { return 'unknown' }
    $source = [string](Get-P0ForegroundProperty -Object $Data -Name 'foreground_identity_source')
    $known = Get-P0ForegroundProperty -Object $Data -Name 'foreground_known'

    # 字段缺席时不要按 known 猜：装的是不含该字段的旧 APK 时，猜出来的结论会把
    # "这个构建根本没有自举"伪装成"自举没触发"，两者要采取的行动完全不同。
    if ([string]::IsNullOrEmpty($source)) { return 'unknown' }
    switch ($source) {
        'bootstrap' { return 'bootstrap' }
        'event' { return 'event' }
        'unknown' { return $(if ($known -eq $true) { 'unknown' } else { 'unset' }) }
        default { return 'unknown' }
    }
}

<#
自举读数的自洽校验：自举身份**必须**是 package 级、无 activity，且 tracker 自己也承认是自举。

这一条不是形式主义。自举唯一被允许做的事就是"用窗口自报的包名补一个 package 级身份"；
若它带回了 activity，说明有别的路径在编造证据，而编造出来的 activity 会进确认前后的
逐字段相等比较——那比没有 activity 危险得多。
#>
function Test-P0BootstrapSelfConsistent {
    param([Parameter(Mandatory)][AllowNull()]$Data)

    $activity = [string](Get-P0ForegroundProperty -Object $Data -Name 'activity')
    $known = Get-P0ForegroundProperty -Object $Data -Name 'foreground_known'
    $package = [string](Get-P0ForegroundProperty -Object $Data -Name 'package')
    $tracked = Get-P0ForegroundProperty -Object $Data -Name 'tracked_identity'
    $trackedBootstrapped = Get-P0ForegroundProperty -Object $tracked -Name 'bootstrapped'

    $issues = [Collections.Generic.List[string]]::new()
    if ($known -ne $true) { $issues.Add('foreground_known 不为 true') }
    if ([string]::IsNullOrEmpty($package)) { $issues.Add('package 为空') }
    if (-not [string]::IsNullOrEmpty($activity)) { $issues.Add("activity 非空（$activity）——自举不得带 activity") }
    if ($trackedBootstrapped -ne $true) { $issues.Add('tracked_identity.bootstrapped 不为 true') }
    return [pscustomobject]@{ Ok = ($issues.Count -eq 0); Issues = @($issues) }
}

<#
整个检查的结论。**四态，"没复现"独立成一态**：

- `passed`        重绑前是 event、重绑后是 bootstrap 且自洽 —— 自举分支真的被走到了
- `not_reproduced` 重绑后仍是 event —— 场景没构造成功（重绑期间有窗口事件），
                   **判据未触达，不许记成通过**；这正是 2026-08-01 真机那次的形态
- `failed`        重绑后是 unset（自举该生效却没生效），或自举读数不自洽
- `unavailable`   读不出字段（旧 APK / 响应异常），无法判定

`Before` 允许是 `unknown`：基线只用于说明"重绑前身份是事件来的"，读不到不影响主判据。
但 `Before` 若已经是 `bootstrap`，说明现场并不是干净的事件身份起点，同样算没复现。
#>
function Get-P0BootstrapVerdict {
    param(
        [Parameter(Mandatory)][string]$Before,
        [Parameter(Mandatory)][string]$After,
        [Parameter(Mandatory)][bool]$AfterSelfConsistent
    )

    if ($After -eq 'unknown') {
        return [pscustomobject]@{ Verdict = 'unavailable'; Reason = '重绑后读不出 foreground_identity_source（旧 APK？）' }
    }
    if ($Before -eq 'bootstrap') {
        return [pscustomobject]@{
            Verdict = 'not_reproduced'
            Reason = '重绑前身份已经是自举来的，起点不是干净的事件身份；请先让设备产生一次窗口事件再跑'
        }
    }
    if ($After -eq 'event') {
        return [pscustomobject]@{
            Verdict = 'not_reproduced'
            Reason = '重绑后身份仍由窗口事件建立——重绑期间有窗口事件到达，场景没构造成功；自举分支未被触达'
        }
    }
    if ($After -eq 'unset') {
        return [pscustomobject]@{
            Verdict = 'failed'
            Reason = '重绑后前台身份仍未建立（identity_unset）——自举该生效却没生效，正是它要修的症状'
        }
    }
    if (-not $AfterSelfConsistent) {
        return [pscustomobject]@{ Verdict = 'failed'; Reason = '自举读数不自洽（见 issues）' }
    }
    return [pscustomobject]@{ Verdict = 'passed'; Reason = '' }
}
