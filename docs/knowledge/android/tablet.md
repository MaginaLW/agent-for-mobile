# Android 平板知识册

> 当前状态：🔵 PA2553 日常横屏为当前平板基线。T0-L schema v5 clean producer
> `4ca32b131007df58f7752c5ee9b2d049cb1cd54e`（42/42、coverage 41/41、独审 0/0/0）已在 r3 真机正确
> fail-closed，并以 main `a7940d5` 合入；r3 evidence 为 `bd64ea5`。T-L1 v2 diagnostic-only 契约/gate
> 已合 main `589421a`；隔离只读 producer 基线固定为 `b5769df7baba075fda47aec17f249a5caa124b92`。
> fixed SHA `2635fc9f5eb229340870b0cdd599cefad97a9b91` 的首次真机 C1a 已冻结失败；修复后的 fixed SHA
> `4b96f89a6622eb8b5fe04bd249571c7d77936b25` 已由唯一 run `tl1-c1a-20260826t125127z-354a7b4b0ed5`
> 建立 trusted origin/read-only sidecar。真实诊断仍 blocked；app 未合 main，`runtime_evidence`/layout/
> 微信/editor/T-L1/P0/execution 仍未放行。A3/C1b 第一批 pure-a11y 合同、producer 与受控 runner 已无机
> 完成：observation 49/49、coverage 89/89、host fake-ADB 26/26、Android Debug 71/71、Release 33/33；
> 本轮 real ADB=0。下一步是固定新 SHA并针对该 SHA取得一次新授权，C1a 授权不可复用。

## 当前能力边界

- 手机与平板复用 Android 执行器和 MCP 架构，但现有 P0 几何仍以手机竖屏为基线。
- `P0FocusProbeValidator` 要求 `h>w` 且 `h/w` 在 `1.4..2.7`；4:3 竖屏与全部横屏可能正确
  fail-closed。不得删除这道门来换成功率。
- snapshot/OCR 多处仍以整屏为坐标系；在分屏、自由窗或微信双栏下，标题、IME 焦点、输入框和消息
  气泡可能分属不同 pane。未建立 window/pane 身份前，禁止危险输入与发送。
- 首轮 T0-L readiness 仍是横屏、微信前台、全屏单 OS app window、边界覆盖当前显示、默认显示缩放、
  采集稳定、非浮动 IME；它是旧的保守入口，不再定义目标设备形态。vivo 原生应用多窗须走新版 T-L1
  window/pane 只读探针；任何路线 P0 都仍 unsupported。
- OS 单窗口不等于微信内部单 pane。横屏微信可能同时展示左侧会话列表和右侧目标会话；未建立唯一
  target pane、title/input/message 同 pane 与 layout epoch 前，禁止危险输入和发送。
- **用户 2026-08-25 决定**：项目尽量适配设备，不通过关闭设备功能换成功。vivo 横屏应用多窗/同 App
  双窗口是日常基线；关闭它最多只能用于显式对照实验，不能写成部署前置、产品要求或最终验收条件。

## T0-L 已实现画像

- 设备：manufacturer/model/product/device、Android/API/ABI；ADB serial 与 build fingerprint 只落 hash。
- 显示：physical/override size、density、smallestWidthDp、rotation/orientation；任一 size/density override
  都阻断默认显示基线。
- 窗口：application window 数量、前台 package/activity、app window bounds、windowing mode。
- 输入：默认 IME、IME visible/floating/session；解析不出记 `unknown`，绝不猜。

T0 当前只覆盖设备/显示/姿态/窗口/IME 的固定只读 ADB 查询；不安装 APK、不启动 App、不截图、
不改设置、不接 gateway。ROM 安装、权限与后台策略属于 T0 后续分层探测，不得混入这次只读入场。
即使只读 readiness accepted，也仍须保持 `p0_capability=unsupported`，直到微信 app window/pane、
目标输入焦点与消息后验在该平板上分别验证。

T0-L **尚未机械证明** font scale、实体键盘、system-bar/taskbar/cutout insets 或多 display；这些字段必须
由未来 T-L1 受控 producer 与真机数据补齐。ROM 的 USB 安装确认、a11y、overlay、notification、后台/
电池策略也不属于本次纯 ADB intake；以后按厂商和能力分层验证，再路由到厂商册。

## vivo PA2553 / Android 16 · 2026-08-24

- 证据：`tablet-t0-20260823T162008Z-5e4e0186`；只保存 SHA-256 设备标识，不保存 raw serial/fingerprint。
- 已知画像：vivo PA2553（product/device DPD2437）、Android 16 / API 36、arm64-v8a；physical
  1968×2800、400dpi、无 override；默认输入法为 vivo Pad IME。
- 采集时屏幕亮、已解锁、勿扰关闭、IME 未显示且非浮动；前台为 Chrome CustomTab。窗口中同时有一个
  fullscreen 2800×1968 和一个 pinned 1013×570，说明当时为横屏且非单窗口，因此正确 blocked。
- schema v1 没有持久化 raw dumps，不能事后判定 rotation/sw 是缺席还是歧义，也不能补写
  capture consistency。旧证据保持 `device_class=unknown` / `intake=inconclusive`，不得修绿。
- 新候选只用固定 `am get-config` 的唯一当前 `swNNNdp` 决策 device class；activity 全局配置若存在则必须
  与其一致。窗口尺寸回退只在唯一前台 owner、fullscreen、原点为 0,0 且边长严格匹配 effective wm size
  时用于 current orientation；冲突、重复、历史 config 或采集前后漂移均返回 unknown/blocked。
- 下一次 T0-L（主会话明确通知连接后）：关闭无关 Chrome、画中画/pinned 与其它 App 分屏/自由窗，断开
  实体键盘，平板锁横屏；微信停在文件传输助手会话页，输入框清空、键盘收起。**保留 vivo 应用多窗**及
  真实日常内部单/双 pane，不要求用户关系统功能或强行切成手机 UI；交给 T-L1 只读探针判定。

## schema v4/v5 受控结果 · 2026-08-25

- v4 只读 run `t0l-landscape-20260825T113747Z-da2fa68d` 已取得 PA2553 / Android 16 画像：physical
  1968×2800、400dpi、`smallest_width_dp=787`，但 rotation、current size 与 foreground 均不可可靠判定；
  两个窗口都投影为 `[0,0,2800,1968]`，v4 没保存也没比较 WindowState identity，无法证明是一个对象重复输出
  还是两个不同窗口。readiness 因此保持 blocked；历史 v4 JSON 不迁移、不补判。
- v5 候选 `135010863ef395a0cb8aacfa625ae87a2453b1dd` 改为 topResumed 权威、identity canonical、强可见性、
  focus/display/type 关系、default-display rotation 严格定域、状态/IME 初末双读与 run-wide 脱敏标签；离线
  fake-adb 42/42、required coverage 41/41、独审 P0/P1=0。即使 readiness accepted，P0 也恒 unsupported。
- 首条固定 v5 C0 `t0l-v5-landscape-20260825T125508Z-13501086-r1` 只执行一次入口，`adb devices`
  识别到 0 台设备后 exit 1；查询表未继续、无 profile/evidence、未重跑。这是连接/发现前置失败，既不验证
  也不否定 v5 解析。下一次必须在用户重新确认 USB 连接与调试授权后使用全新 run/worktree，不能复用本轮。
- 重连后的 r2 `t0l-v5-landscape-20260825T132258Z-r2` 唯一入口 exit 0：tablet/微信前台/awake/keyguard/
  zen/IME 初末稳定；两个强可见、owner=微信的 `base_application` identity 均为 `multi_landscape`，另有
  rotation 歧义、4 个强可见 unknown type、18 个 malformed window field、focus absent。readiness 按
  `application_window_count_not_one` 等原因正确 blocked，P0 unsupported；JSON SHA-256（Windows worktree）
  `41ed9725fe27d3af40caeae7f200fa0636870ed7bac5fbe8a13d1c5ef3375f42`，main evidence commit `d076345`。
- T0-only clean producer `4ca32b131...` 的 r3 `t0l-v5-clean-landscape-20260825T134257Z-r3` 也只执行
  一次入口并 exit 0；assessment 与 r2 逐字段一致。r3 仅少一个不可见 unknown fullscreen block，block 21→20、
  malformed field 18→17，两个强可见微信 base window、4 个强可见 unknown type、focus absent 与全部阻断原因
  均不变。Windows worktree JSON SHA-256 为 `5e6699bdcf71aaf200d6f7610b639335d982d1c12f3749ed49a61571d97e44dd`；
  producer/main merge 为 `4ca32b1...` / `a7940d5`，evidence main commit 为 `bd64ea5`。
- vivo 官方将“应用多窗”定义为横屏时并排展示同一应用不同层级界面，并宣传“一个 App，双窗口”；因此
  `multi_landscape` + 两个微信 base window 与系统原生设计一致是**有官方旁证的推断**，不是仅凭字段名
  断言内部实现。后续应建模双 window/pane，不能要求用户关闭该功能来满足旧单窗门。

## T-L1 v2 / C1a 无机冻结、首次失败与修复后取证 · 2026-08-26

- diagnostic-only contract/schema/validator/gate 源提交 `c8bd3e3...`，以 main `589421a` 合入；gate
  self-test 5/5、cases 24/24、required coverage 24/24，输出恒为 layout/P0/execution false。
- 隔离 producer 候选 `b5769df7baba075fda47aec17f249a5caa124b92` 位于 `codex/tablet-tl1-v2`；只读枚举
  Accessibility window/node，未接 ToolRegistry/MCP，不含 action、gesture、input、settings、截图、文件写入或
  sleep，production capability 固定 `runtime_runner_not_connected` / unavailable。
- producer 专项 33/33；全量 Debug 350/350、Release 259/259，`assembleDebug` 成功；标准仓库检查的 T0、
  T-L1、dispatch 28/28、runner 82/82 与凭据扫描全部通过，独立终审 P0/P1/P2=0。以上全是无设备结果，
  不构成 runtime evidence、微信布局验证或 P0 放行。
- C1a 候选位于 `codex/tablet-tl1-c1a`：从当前 main 干净移植、机械绑定 producer/T0 六个基线 blob；
  debug-only provider 与独立受控 runner/attest 已实现，本轮固定 c1/等待至少 900 ms/c2、不补拍；release
  全包 absence 通过。C1a 15/15、coverage 45/45、self 3/3；全量 Debug 373/373、Release 261/261，
  标准全门通过，跨层独审 P0/P1=0。这组计数只描述 fixed SHA `2635fc9...` 的 pre-C 基线，不能转写成
  当前 A 修复后的全门结果。
- 第一个明确授权的 C 轮在安装阶段超时；脚本没有生成 `run_id`，没有调用 c1/c2，也没有产生 evidence。
  本轮按“安装失败不自动重试”冻结。用户随后另行明确授权一次重试，才启动下一轮。
- 第二轮唯一 run `tl1-c1a-20260826t114535z-63667b68ce4f` 只调用 c1/c2 各一次，capture token/ID 分别为
  `c1`/`capture-c1` 与 `c2`/`capture-c2`，时间间隔 1982.304 ms；result 单次消费后会话结束，没有补拍或
  自动重试。observation 为 `diagnostic_status=blocked`，trusted-runtime validation 失败，无 success sidecar，
  所以 origin 未建立；runtime/layout/微信布局/editor/P0/execution 均为 false/unsupported。
- 第一条根因是 Windows 普通 `adb shell` stdin 将 T0 原始 23,865 bytes 中 747 个 CRLF 归一为 LF：宿主
  artifact hash `43d9529ce10dca04c4bc60528d66376844f23edf0ebea9b63f0de04e8ff48fed`，provider 所见
  `f9d548...`，触发 `upstream_t0_hash_mismatch`。修复只把 T0 write 改为 `adb exec-in content write` 的
  binary stdin，并传 raw canonical URI；只读 endpoint 仍走 `adb shell content read` 与远端 POSIX 引号。
- 第二条根因是静态页面没有新无障碍事件，两帧 raw event revision 合法地保持 15/15，而旧跨帧严格递增
  断言把它误判成 `capture_order_invalid`。A 修复仅在 debug-only C1a adapter 公开可逆 logical marker：
  `logical revision = raw event revision + c1/c2 capture ordinal`；用 token 可还原 raw，帧内 event 漂移、
  跨帧 raw 下降与溢出仍 fail closed，producer/T0 六个 baseline blob 不改。
- 修复不会删除真实诊断 blocker：`focus_fallback_insufficient`、`focus_target_conflict`、
  `node_binding_invalid`、`region_candidate_missing`、`target_title_not_unique`、
  `target_window_pane_missing`、`window_pane_bijection_invalid` 仍须保留。因此即使后续 origin 能建立，
  本次形态仍应保持 diagnostic blocked，且不会提升 runtime/layout/P0/execution。
- A 修复的标准全门已通过：C1a 15/15、required coverage 46/46、self 3/3，Debug 377/377、
  Release 261/261、dispatch 28/28、runner 82/82、T-L1 24/24；assembleDebug、release absence 与凭据扫描
  全绿，独立终审 P0/P1=0。新 fixed SHA 为 `4b96f89a6622eb8b5fe04bd249571c7d77936b25`；失败 SHA
  不复用。用户现场全程保持 vivo“应用多窗”，runner 未读取该开关值，也未为取证或修复修改设备设置。
- 唯一成功 C1a run `tl1-c1a-20260826t125127z-354a7b4b0ed5` runner exit 0。fresh APK 的 local/pre/post
  base SHA-256 均为 `0f2e5922e5f4c12b03b74fe06b7e0e40aa870ec376eca2cf06a4984ac2e4b288`；success
  sidecar 给出 `c1a_origin_binding_verified=true`、`c1a_probe_entrypoint_read_only=true`、schema valid，
  cleanup=`not_required`。标准 evidence 恰好五文件，无 failure/tmp。
- Windows T0 修复已获真机机械证明：profile 与 upstream 均为 23,865 bytes，包含 747 个 CRLF，且无 bare
  LF/CR；两者 SHA-256 同为 `6f5b1539d3d09bf77e26dc2ba5d700d11857c3edac84eef33fee03df4a81c316`，
  sidecar 标记 `original_bytes_forwarded=true`。因此 `adb exec-in` binary stdin + raw canonical URI 在真机
  保持了原始 bytes，不再出现失败 run 的 CRLF→LF 漂移。
- c1/c2 各一次，对应 `capture-c1`/`capture-c2`，帧间 delta 2023.223 ms；host wait 905 ms、总 span
  3140 ms、recapture=0。两帧都是横屏 2800×1968，并稳定枚举两个 `com.tencent.mm` application window：
  `[0,0,985,1968]` 与 `[989,0,2800,1968]`。
- 取证只证明来源与只读边界，不证明布局。validation 保持 `diagnostic_observed=false`、
  `diagnostic_status=blocked`，七项 reason 为
  `window_pane_bijection_invalid`、`target_window_pane_missing`、`node_binding_invalid`、
  `target_title_not_unique`、`region_candidate_missing`、`focus_fallback_insufficient`、
  `focus_target_conflict`；runtime/layout/微信/editor/execution 均 false，P0 unsupported。因此 C1a 取证
  成功不等于 T-L1 通过，不能进入 T-L2。
- 本 run 没有修改 settings、没有启动目标 App、没有截图；用户现场保持 vivo 日常“应用多窗”，机械证据是
  T0 `multi_landscape` 与两个稳定 a11y application window，并不构成系统开关值 attest。它证明可信只读诊断
  可在该双窗形态下完成，而不是布局已经适配。direct C1a runner 未走 dispatch，按其合同不写 ledger；本次以五文件 evidence
  和 `docs/runs/2026-08-26-T-L1-C1a只读取证成功.md` 冻结归因，不补造 ledger 行。

## A3/C1b 第一批设计结论 · 2026-08-26

- v2 observation/schema/validator/fixture 与两条 C1a evidence 永久冻结，不追溯换语义；C1b 另开
  `tablet-layout-observation/c1b-v1`。现有 `rootStatus=readable` 不能被回填成“语义树可用”。
- Android 平台 window type 必须同时保存 raw code 与闭合名称。API 36 code `7` 记为
  `window_control`，只表示控制关联窗口的系统 window；不能事后把 C1a 的 `unknown` 断言成分栏线。
- 每个 window 独立记录 root-handle 状态、root→window exact/mismatch/unknown、subtree complete/truncated/
  read-error/not-attempted、root child 数、visited/正几何可见/focused-editable/read-error 数与 budget exhaustion。
  `complete` 只表示完整遍历平台暴露的树；`child=0 + visited=1 + positive-visible=0` 仍是 opaque。
- projection pane 只把 application window/root 投影到 run-local `awN/apN`；首版 `semantic_role=unknown`、
  evidence 为空。禁止用左右、宽窄、layer、active/focused、包名、scrollable 或 editable 推断
  navigation/conversation。左右镜像交换必须保持全部语义结论不变。
- `AccessibilityWindowInfo.title` 只做 caller-known expected hash 的 window-level match state，不保存明文或
  未命中内容 hash，也不冒充 toolbar title。direct input focus 只有 refresh、focused/editable/visible/enabled、
  微信 owner、正几何、windowId 与唯一 focused application window 全部一致时才可记 `editor_known`；仍不得
  选择 conversation/target。只有 window focus 时记 `window_only`，不报成 editor 冲突。
- 第一批未来 fresh C1b sidecar 最多提升可信来源、微信 window ownership、root projection、双 application
  window topology 与 hidden IME；navigation/conversation/target/regions/layout/微信布局/editor/P0/execution
  一律 false/unsupported。若 fresh C1b 仍 opaque，下一步另审 pane/window-bound 视觉通道，不关闭 vivo
  “应用多窗”，也不回退整屏 OCR/坐标猜测。
- **observation 不能靠 caller 传入的 SHA 自证真机来源**：schema 正确、run id/producer SHA/APK hash 与参数一致，
  最多叫 `runtime_binding_inputs_match`。只有宿主独立重算 clean HEAD、实现文件、签名/APK、唯一设备/
  fingerprint/boot、provider challenge/control transcript、T0 原始 bytes、c1/c2 计数与 evidence hash，并由
  closed success sidecar 绑定后，consumer 才能提升 `runtime_origin_verified/runtime_evidence`。
- **重复读取失败不能伪装成跨帧稳定（C1b 无机复核，2026-08-26）**：display/type/layer/touchable/
  active/focused 等 window shell 字段若两帧都异常，不能各自回退到合法默认值再得到“相等”。wire 没有
  显式 unknown 状态的关键字段应丢弃该 window 并标记 inventory truncated；成功读到未映射 type code 可
  保留 raw code，但必须阻断完整 topology/focus/hidden-IME。producer 的 focus fail-closed 条件还必须能由
  consumer 从持久化的 root/subtree/node/pane/bounds/count 重新算出；只在内存 diagnostic 里记失败而不让
  wire 结论变化，会造成 producer 诚实报 unknown、consumer 却期待 absent/window_only 的跨层错位。
- **传输程序也是来源链的信任根（C1b 无机复核，2026-08-27）**：仅要求 `-AdbPath` 是绝对普通文件，
  不能支撑“独立来源绑定”。C1b runner 因而只接受 `ANDROID_SDK_ROOT == ANDROID_HOME` 下 canonical
  `platform-tools/adb.exe`，在采集前后及 sidecar 发布读回时绑定 executable hash、exact `adb version` hash、
  Installed-as path 与解析版本。该规则明确了宿主信任边界；它不声称能抵抗已完全控制本机 SDK 的攻击者。
- **不完整 inventory、无效 identity 与 replay ledger 都要向拒绝方向收敛**：`windows_truncated=true`
  时即便 IME tuple 长得像 hidden，也不能产生 hidden observed/verified；负 window ID（含平台 `-1`
  sentinel）不能形成 exact binding 或跨帧 token；每帧 `ime.capture_token` 还必须 exact 绑定同帧
  `capture.token`。进程内 consumed ledger 固定 128 项且永不淘汰；容量满后以 `replay_ledger_full` 拒绝新
  identity，不能为了有界内存而让最旧 nonce 再次可用。failure evidence 的 `cleanup=completed` 也只能来自
  与最后可信 generation/counter/committed-prefix 完整一致的闭合 abort terminal control；只看状态名不够。

## 横屏路线与硬边界

1. **T0-L** 只证明设备/姿态/OS window 可用于继续测量；固定输出
   `wechat_layout_unverified` + `tablet_landscape_p0_unimplemented`，P0 unsupported。
2. **T-L1 无机契约** v2 synthetic schema/validator/gate 已合 main；fixture 只能验证诊断契约，不能产生
   runtime、微信验证或执行授权。未显式 fixture mode 时，入口在读取 caller 文件前固定 unavailable。
3. **T-L1 C1a/C1b 只读 producer**：clean-port C1a 已在 `4b96f89...` 建立可信 origin/read-only，并真实
   观察到 vivo 同 App 双 OS window，但七项诊断 blocker 使 T-L1 保持 blocked。C1b 第一批只验证 window
   inventory/owner、root binding/subtree、run-local root projection、focus inventory 与 hidden IME；它不寻找
   navigation/conversation/target，不证明 toolbar/title-node，也不划分 message/input regions。即使 fresh C1b
   sidecar 将 origin/ownership/root projection/topology/IME 置真，layout/T-L1/P0/execution 仍称 blocked/
   unsupported。若 pure-a11y 仍 opaque，下一步另审 window/pane-bound 视觉合同；不得把目标语义塞回本合同，
   也不得关闭 vivo“应用多窗”或退回整屏坐标猜测。
4. **T-L2** 才实现危险链：每腿 fresh layout proof；prepare/type/确认/Enter/发送后验/teardown 传播同一
   display + app window + pane + layout epoch。首版禁用 IME-only 与整屏坐标兜底。
5. 四腿带外 OCR 必须覆盖 Allow/Stale/Deny/Reentry、保留 X/Y 并裁 target pane；unavailable、unreadable
   或 inconclusive 均不得把横屏批次判通过。
6. 手机 `P0FocusProbeValidator` 的 `h>w`、比例和手机式标题/底栏规则继续保留；横屏是独立策略，不在
   手机路径上删门放行。竖屏平板兼容在横屏闭环后另批验证。

## 参考

- Android 官方建议按动态 App 窗口而非设备型号适配，并以 window size classes 表达可用空间：
  https://developer.android.com/develop/ui/views/layout/use-window-size-classes
- Android 16 在大屏上会忽略部分方向/宽高比/可调整大小限制，因此不能依靠锁竖屏规避适配：
  https://developer.android.com/develop/adaptive-apps/guides/app-orientation-aspect-ratio-resizability
- vivo 官方“应用多窗”说明（横屏同一应用不同层级双窗口，设置入口为“显示与亮度 > 应用多窗显示”）：
  https://bbs.vivo.com.cn/newbbs/thread/32933113
- vivo Pad 官方产品页（“一个 App，双窗口高效浏览”）：https://www.vivo.com.cn/vivo/vivopad
