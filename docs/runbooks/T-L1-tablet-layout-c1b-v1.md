# T-L1 C1b v1：平板横屏 pure-a11y 只读取证

## 适用范围

本规程只用于 vivo PA2553 / Android 16 的日常横屏“应用多窗”现场。项目适配设备原生双窗口形态；
不得为了让 gate 变绿而关闭应用多窗、改系统设置、启动目标 App、截图、OCR 或注入任何动作。

C1b 第一批只观察 accessibility window/root/subtree/focus/IME 拓扑。即使成功 sidecar 成立，也只可能
验证来源、微信 window ownership、root projection、双 application-window topology 与 hidden IME；
navigation/conversation/target/regions/layout、微信布局、editor action、P0 与 execution 仍固定为
false/unsupported。

## A 道固定条件

通知用户连接平板前，必须同时满足：

1. 工作树 clean，并把完整 40 位 commit SHA 固定到本次候选；
2. C1b observation gate、host fake-ADB gate、旧 v2 回归全部通过；
3. C1b Debug/Release JVM、`assembleDebug`、C1b release-absence 与凭据扫描通过；
4. 独立审查无 P0/P1；
5. 用户针对该 C1b SHA 明确授权一次真机 build/install/只读采集。C1a 授权不能复用。

## 唯一入口

在固定 SHA 的 clean worktree 中执行：

```powershell
pwsh -NoProfile -File scripts/run-tablet-layout-c1b.ps1 `
  -AdbPath <绝对路径\adb.exe> `
  -ExpectedCommitSha <40位固定SHA> `
  -Provision
```

runner 只允许一次 fresh build、一次 `adb install -r -t`、一次 T0 v5、一次 `c1`、宿主等待至少
900 ms、一次 `c2`、一次 result。不得卸载、自动重试或补拍。若无障碍服务尚未启用/绑定，runner 只输出
`needs-user` 并停止；用户处理后必须重新固定现场和授权，不能把下一次启动算作同一尝试。
所有 bounded status poll（包括中间 `capturing_*`）都必须逐条通过完整 control tuple 校验；任一字段漂移时立即失败，
不得继续轮询并用后续正常 terminal 掩盖已经出现的畸形响应。

## 成功产物

成功目录为 `docs/runs/evidence/<run_id>/tablet-layout-c1b/`，恰含：

- `upstream-t0-v5.json`
- `tablet-layout-observation-c1b-v1.json`
- `tablet-layout-observation-validation-c1b-v1.json`
- `tablet-layout-c1b-sidecar-v1.json`

sidecar 必须独立绑定 fixed SHA、实现文件、provider build challenge、APK 与 signer、唯一设备/fingerprint/
boot、T0 原始 bytes、c1/c2 generation/counters/timing、control transcript、三份 evidence 路径与重算 hash。
observation validator 本身永远不能自证 runtime origin；只有 sidecar 全部闭环后，consumer 才能把
`runtime_origin_verified/runtime_evidence` 置真。

## 失败与冻结

安装、T0、provider、capture、时序、schema、hash、设备/APK 漂移或 cleanup 任一失败，都只原子保留
`tablet-layout-c1b-failure.json` 与已经产生的只读证据；不发布 success sidecar，不自动重试，不借 fixture、
C1a 或 v2 evidence 补造成功。尚未消费 result 的 session 只允许一次 abort cleanup；abort 不是重拍。
abort 返回还必须与发起前最后一个已验证 generation/counters/committed prefix 及闭合 terminal tuple 一致；畸形返回只能
记 `cleanup=failed`，不能因出现 terminal 状态字符串就记为完成。尤其 `ABSENT/t0_pending`、`ABSENT/session_busy`
或 `ABSENT/generation_exhausted` 不属于 abort cleanup 成功终态。

## 结果解释

- `complete + childCount=0 + visited=1 + positive-visible=0` 表示完整观察到 opaque root，不是树可用；
- `window_only` 表示只有 window focus，不是 editor 或目标会话；
- native window title 的 fixed-hash match 不是 toolbar/title-node 或 target proof；
- pure-a11y 仍 opaque 时，下一步另审 window/pane-bound 视觉合同，不能关闭应用多窗或回退整屏坐标猜测。
