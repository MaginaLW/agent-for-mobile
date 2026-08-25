# T0 平板只读 intake

> 目标：在任何 gateway 安装、App 导航或监督式发送之前，先取得一份去明文的平板画像。
> 本流程是 A/只读取证，不消耗批次 4 真机腿，也不代表 P0 已支持该平板布局。

## 边界

入口：`scripts/run-tablet-intake.ps1`。

只允许以下设备读取：固定 getprop、无参数 `wm size/density`、固定 `am get-config`、固定 dumpsys、两项
`settings get`。入口不复用 provision/session，不会 install、启动/停止 App、唤醒、解锁、输入、
截图、切 IME、改 settings、push/pull/forward 或连接 gateway。所有原始 dumpsys 只驻内存；
设备 serial 与 build fingerprint 只落 SHA-256。这是可关联的假名化标识，不等于不可逆的匿名化。
WindowState identity 只在单次进程内用于初末比较；画像既不落原 token，也不落其稳定 hash。

## 使用

先人工保证只连接一台设备并完成 USB 调试授权。开发会话不得直接运行；需在单独的只读设备会话中执行：

```powershell
pwsh -NoProfile -File scripts/run-tablet-intake.ps1 -AdbPath 'C:\Android\platform-tools\adb.exe'
```

`-AdbPath` 必须是存在的绝对路径。脚本要求 `adb devices` 恰好只有一条记录且状态为 `device`。

输出固定写入：

```text
docs/runs/evidence/<run_id>/tablet-profile.json
```

退出码：

- `0`：已取得 tablet 画像；只表示只读 intake 完成，不表示 P0 可运行。
- `2`：画像已取得，但 `smallest_width_dp < 600`，按默认门拒绝为 phone。
- `3`：画像已取得，但 smallest width 无法可靠解析，分类 inconclusive。
- `1`：ADB、设备数量/授权、查询或安全写盘失败；不产生可冒充成功的画像。

## 首批能力门

`smallest_width_dp >= 600` 只说明设备分类为 tablet。当前 T0 横屏基线的 readiness accepted
还必须同时满足：

- landscape，且不是 4:3；
- 屏幕 awake、未锁、`zen_mode=0`；
- 唯一合法 `topResumedActivity`（仅其明确 absent 时才允许唯一 `mResumedActivity` fallback）
  选出的 top package 是 `com.tencent.mm`；`mCurrentFocus` 只用于窗口绑定，绝不建立 foreground；
- 恰好一个强可见、identity/display/type 均可靠的 OS BASE_APPLICATION window，owner 与 top 微信一致，
  `windowing_mode=fullscreen`，且 bounds 精确为 `[0,0,currentWidth,currentHeight]`；
- focus 必须绑定到上述同一 window identity；identity 缺失/冲突/重复、弱可见性、可见应用子窗、
  application overlay 或未知类型窗口都阻断。明确识别的系统栏/壁纸背景只做诊断，不混入 BASE 计数；
- `wm size` 与 `wm density` 均不得出现 override；即使 override 与 physical 数值相同也会阻断，
  以机械保证这两项系统显示缩放处于默认态；
- 采集末端重读的 `am get-config`、wm size/density、rotation、top activity、决策相关窗口语义，
  以及 awake/keyguard/zen/IME 状态与初次观察一致；窗口集合按进程内 identity canonical 比较，
  block 顺序重排不算漂移，identity 替换或语义/来源变化算漂移；
- IME 若可见，不得是 floating；任何关键字段 unknown 都 fail closed。

竖屏或 4:3 **仍会完成 intake 并落画像**，但 readiness blocked。分屏、多窗、PiP/pinned、
自由窗、letterbox/兼容边框、浮动 IME 同样 blocked。T0 没有验证微信单/双栏、目标会话 pane
或输入框几何，所以即使 readiness accepted，
`p0_capability` 仍固定为 `unsupported`，且必须同时包含 `wechat_layout_unverified` 与
`tablet_landscape_p0_unimplemented`：前者表示微信 pane 未验证，后者表示平板横屏 P0 策略未实现。
不要为了把画像变绿而改设备状态；
T0 只观察，不纠正。

## schema v5 与 Android 16 严格回退

新采集固定写 schema v5；历史 schema v4 证据不迁移、不补判，继续保持原有 blocked 结论。
v5 在 `observations.initial/final` 保存最小脱敏 foreground、rotation、current-size、window/focus
与状态摘要，并在 assessment 保存固定枚举的 capture consistency reasons。foreground 只保存最终
selected 值与各来源计数，不保存未选候选；window 只保存 run-local `w0/w1` 标签、分类、几何与
绑定关系，不保存 raw identity。重复、冲突、非法或超大数值都形成 unknown/ambiguous 诊断，
不得抛出 overflow 后中止，也不得从合法+非法混合证据中挑合法值继续。

- `smallest_width_dp` 决策必须来自固定只读 `am get-config` 输出中唯一列首 `config:` 行、
  唯一完整 `swNNNdp` qualifier。activity `mGlobalConfiguration` 缺席时来源为 `am_config`；
  两者都有唯一合法值时必须相等，来源为 `activity_global_cross_checked`。
  `am get-config` 缺失/歧义、activity 歧义或两者冲突时分类 unknown。
- `wm size/density` 只是面板/窗口诊断与几何一致性证据，不得推导
  `smallest_width_dp`，也不得影响 tablet/phone 决策。
- rotation **明确 absent** 时，只有唯一个强可见 BASE_APPLICATION fullscreen 窗口同时满足：
  top 是微信、identity 可靠且唯一、display=0、focus 绑定同一 identity、无可见 overlay/未知类型/
  应用子窗、owner 等于已确认 top package、bounds 从 `(0,0)` 开始、两条边与默认 `wm size` 严格匹配，
  才可以该 bounds 得出当前宽高，来源记为 `fullscreen_window`。pinned/freeform/split 窗口
  不参与方向推导，但仍会阻断 readiness。
- rotation 前后均缺席时，只比较上述可证的当前宽高；任一端冲突，或 am config/wm/top/window
  任一项漂移，都 fail closed。`am_config`/`activity_global_cross_checked`、rotation/window、
  physical/override 等来源即使数值碰巧相同，单端切换也明确记为 changed 并阻断。
- rotation 只窄接受 `rotation=1`、`rotation: 1`、`mRotation=ROTATION_1` 与 ROM 中的
  `rotation 1` 这类 0..3 单值，而且必须绑定明确的 default display scope。default display block
  内分行字段和 display/window 同值交叉证据可 canonical 合并；未定域、secondary display、
  合法+非法、冲突或超范围 token 都是 ambiguous。
  初末从 `rotation 1` 变为 `rotation 3` 即使都是横屏，也作为采集漂移阻断。

这些回退只用于 T0 分类与只读几何画像；不会把 `p0_capability` 从 `unsupported` 提升。

## 离线验证

无设备开发的统一入口是：

```powershell
pwsh -NoProfile -File scripts/check-tablet-intake-offline.ps1
```

该 gate **不接受 `AdbPath`**，只会运行 AST 检查与 fake-adb 套件，不发现、连接或查询真实设备。
机器可读报告固定写入：

```text
.checks/tablet-intake-offline-summary.json
```

报告包含每个用例的状态与必需 coverage ID。gate 会机械拒绝 0 用例假绿、缺失必需用例、
schema 契约漂移、非零失败数，或以下三项保证未通过：`exact_read_only_argv`、`schema_v5`、
`p0_always_unsupported`。原始子套件摘要与日志分别位于
`.checks/tablet-intake-offline-suite-summary.json` 和 `.checks/tablet-intake-offline.log`。

T0-L 必需矩阵覆盖：ADB 路径不存在/相对路径/指向目录、0 设备、unauthorized、offline、
`no permissions`、multiple，以及 device+offline/unauthorized 混合时拒绝挑选唯一 `device` 行。
`adb devices` 非零退出、查询超时、unknown/歧义、横屏正向、竖屏阻断、多窗、PiP 与
letterbox 也是必需项。v5 另机械覆盖 foreground 来源优先级/畸形、default-display rotation scope、
focus 关系、window identity/强弱可见性、unsafe type、超大数值、严格 window fallback、identity
canonical capture、awake/keyguard/zen/IME 初末漂移与 window token 隐私 canary。
含空格的绝对 fake-adb 路径与 CRLF/daemon banner 是正向兼容样本。
fake-adb 默认拒绝未列入
白名单的 argv，命令审计要求实际 argv 序列与预期只读序列逐项一致。其余用例继续覆盖
phone、4:3、freeform/pinned/floating IME、vivo Android 16 严格回退、`rotation 1`→3 漂移、
wm size/density override 阻断、run-id 覆盖拒绝与
serial/fingerprint 明文与 window identity 明文/稳定 hash 不泄漏。

超时反例直接以 `Invoke-TabletAdbQuery -TimeoutSec 1` 调用 delayed fake-adb，并要求超时后无完成哨兵、
无画像目录且 `adb.log` 只有 `devices`。这只验证 Windows 上当前 fake 进程树的 kill 契约，
不可写成已用真实 adb server/设备证明。

这些结果只证明 T0 入口、解析和 fail-closed 策略的离线契约；不证明 T-L1 的微信单/双栏、
pane 身份、OCR 区域或真机可用性。T0 也没有采集或证明 font scale、物理硬键盘状态、
状态栏/导航栏/cutout insets，或多 display/外接显示器窗口身份。这些全部转交 T-L1 设计与
后续独立真机阶段，在有新的固定只读查询和可靠反例前，不得将它们写成已验证。
