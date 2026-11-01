# Android 平板知识册

> 可复用的平板设备事实与坑。路线与决定见 [平板设计](../../specs/2026-08-23-Android平板适配-design.md)，当前进展见
> [STATUS](../../../STATUS.md)，C1b 现行运行见 [C1b 规程](../../runbooks/T-L1-tablet-c1b.md)。
> 旧 C1b 主机证据链（2026-10-09 退役）的历史见 git `7a3b069` 及 `docs/runs/` 的 C1b 记录。

## 当前能力边界

- 手机与平板复用 Android 执行器和 MCP 架构，但现有 P0 几何仍以手机竖屏为基线。
- `P0FocusProbeValidator` 要求 `h>w` 且 `h/w` 在 `1.4..2.7`；4:3 竖屏与全部横屏会正确 fail-closed。
  不得删除这道门来换成功率。
- snapshot/OCR 多处仍以整屏为坐标系；在分屏、自由窗或微信双栏下，标题、IME 焦点、输入框和消息气泡
  可能分属不同 pane。未建立唯一 target pane、title/input/message 同 pane 与 layout epoch 前，禁止危险输入与发送。
- OS 单窗口不等于微信内部单 pane；横屏微信可能同时展示左侧会话列表和右侧目标会话。
- **用户 2026-08-25 决定**：项目尽量适配设备，不通过关闭设备功能换成功。vivo 横屏应用多窗是日常基线；
  关闭它最多用于显式对照实验，不能写成部署前置、产品要求或验收条件。

## T0-L 画像范围

- 设备：manufacturer/model/product/device、Android/API/ABI；ADB serial 与 build fingerprint 只落 hash。
- 显示：physical/override size、density、smallestWidthDp、rotation/orientation；任一 size/density override
  都阻断默认显示基线。
- 窗口：application window 数量、前台 package/activity、bounds、windowing mode。
- 输入：默认 IME、IME visible/floating/session；解析不出记 `unknown`，绝不猜。
- 未机械证明：font scale、实体键盘、system-bar/taskbar/cutout insets、多 display；ROM 的 USB 安装确认、
  a11y、overlay、通知、后台/电池策略也不属于纯 ADB intake，需分层验证后路由到厂商册。
- device class 只用 `am get-config` 的唯一当前 `swNNNdp` 决策；窗口尺寸回退只在唯一前台 owner、fullscreen、
  原点 0,0 且边长严格匹配 effective wm size 时可用；冲突、重复、历史 config 或前后漂移均为 unknown/blocked。
- 只读证据必须当时持久化足够判别字段：只存结论不存 identity 的旧 schema（v1/v4）事后无法区分“缺席”与
  “歧义”、或“同一窗口重复输出”与“两个窗口”，旧证据不迁移、不补判。

## vivo PA2553 / Android 16 实测（2026-08-24 至 08-26）

- 画像：vivo PA2553（product/device DPD2437）、Android 16 / API 36、arm64-v8a；physical 1968×2800、
  400dpi、`smallest_width_dp=787`、无 override；默认输入法为 vivo Pad IME。
- 日常横屏应用多窗下，T0-L 看到两个强可见、owner=微信的 `base_application` window，windowing mode 均为
  `multi_landscape`；另有 rotation 歧义、若干强可见 unknown type、malformed window field 与 focus absent。
  readiness 因 `application_window_count_not_one` 等正确 blocked。
- vivo 官方将“应用多窗”定义为横屏并排展示同一应用不同层级界面（设置入口“显示与亮度 > 应用多窗显示”），
  因此“`multi_landscape` + 两个微信 base window = 系统原生设计”是有官方旁证的推断，不是仅凭字段名断言。
- C1a 只读采集（2026-08-26）：两帧横屏 2800×1968，稳定枚举两个 `com.tencent.mm` application window，
  bounds 为 `[0,0,985,1968]` 与 `[989,0,2800,1968]`（两窗间隙 4px）。
- 该形态下 pure-a11y 布局诊断保持 blocked，真实 reason：`window_pane_bijection_invalid`、
  `target_window_pane_missing`、`node_binding_invalid`、`target_title_not_unique`、`region_candidate_missing`、
  `focus_fallback_insufficient`、`focus_target_conflict`。这些是设备事实，修复传输/顺序问题时不得删除。
- API 36 平台 window type code `7` 记为 `window_control`（控制关联窗口的系统 window）；不能事后把旧
  `unknown` 断言成分栏线。
- 采集前现场准备：关闭无关 Chrome、画中画/pinned 与其它 App 分屏/自由窗，断开实体键盘，锁横屏；微信停在
  文件传输助手会话页、输入框清空、键盘收起。**保留应用多窗**，不要求用户关系统功能或切成手机 UI。
- 曾见 `adb devices` 识别 0 台：属连接/授权前置失败，不说明解析逻辑；请用户确认 USB 与调试授权后用新 run。

## Accessibility 读取的坑

- `window.root` 非空不等于语义树可用：`complete + childCount=0 + visited=1 + positive-visible=0` 是完整
  观察到的 opaque root。禁止用左右、宽窄、layer、active/focused、包名、scrollable 或 editable 推断
  navigation/conversation；左右镜像交换后语义结论必须不变。
- `AccessibilityWindowInfo.title` 命中只是 window-level 事实，不是 toolbar 标题，也不能选择目标会话；只有
  window focus 时记 `window_only`，不报成 editor 冲突。
- 静态页面没有新 a11y event，两帧 raw event revision 合法地相等（实测 15/15）；跨帧严格递增断言会误判
  `capture_order_invalid`。顺序标记应可逆地叠加 capture ordinal，且仍拒绝帧内漂移、raw 下降与溢出。
- 重复读取失败不能伪装成跨帧稳定：display/type/layer/touchable/active/focused 等字段两帧都读失败时，不能
  各自回退默认值再判“相等”；应丢弃该 window 并标记 inventory truncated。
- `windows_truncated=true` 时 IME 看似 hidden 也不能判 hidden；负 window ID（含平台 `-1` sentinel）不能
  形成 exact binding 或跨帧 token。
- producer 的 fail-closed 条件必须能由 consumer 从持久化字段重算；只在内存里记失败而 wire 结论不变，会造成
  跨层错位。

## window/pane 视觉证据来源（2026-11-01，静态查阅）

- **适用条件与做法**：pure-a11y root 完整但 opaque，准备视觉路线时先查实际产生者。现有默认 display 截图返回 Bitmap，未携带 native window 身份或截图结果时间戳；fresh generation、a11y revision、相同 bounds 与裁图 offset 均不能单独证明 window/pane 同代绑定。确认 overlay 也推进全局 revision，不能直接用该值替代视觉 layout epoch；预期 IME/insets 变化仍使旧链失效，旧批准不复活。
- **inventory 归因边界**：当前内部 diagnosticCodes 不序列化。固定默认上限 16 且 relabel 不删窗的生产链下，CCC 每帧 4 条且 truncated 可条件推知至少一次必要字段 shell rejection；不能确定具体字段、异常/坏值、丢弃数或是否同时超限，更不能认定 getter/ROM/probe 缺陷。后续有界分类只能扩展可解释性，不放宽 topology/IME 门。
- **验证依据**：两路只读源码核查、存量 CCC observation 与独立设计审查，详见[评审记录](../../runs/2026-11-01-平板视觉合同评审.md)和[合同设计](../../specs/2026-11-01-平板window-pane视觉证据合同-design.md)。本轮无设备/截图/OCR；可信图像来源、geometry/epoch、TTL/同步误差仍未证实，不据此实施或开跑。

## Windows / ADB 宿主坑

- **原始 stdin 的字节风险**：08-26 曾用 `exec-in content write` 验证当时的 binary stdin 链路，属于历史版本经验，
  不作为当前 C1b 写入建议。11-01 当前固定 CCC 已真机验证原 T0 单行 ASCII Base64 → `shell -T` 的远端
  `pipefail`/`toybox base64 -d`/`content write` 链路与原字节哈希匹配；解码/写入任一失败或任意输出仍停止，
  不回退 exec-in/PTY。详见[当前规程](../../runbooks/T-L1-tablet-c1b.md)及[harness 字节边界](../brain/harness.md)；
  成功仅覆盖本轮，不反推旧失败唯一原因或任何环境都可用。
- **`adb -L` listen 只认 `localhost`**（2026-08-29 离线归因）：`adb -L tcp:127.0.0.1:<port> server nodaemon`
  会落入 unsupported hostname 并 `LOG(FATAL)`，Windows 上表现为 adb 进程秒退、WER 记录 `0xc0000409`。
  listen 用 `tcp:localhost:<port>`；client `-H/-P` 可继续用 numeric `127.0.0.1`。
- PC Suite 等手机助手可能占用 TCP 5037 且 adb 版本不同，表现为设备数异常；需要时由用户结束该会话。
- PowerShell `ConvertFrom-Json` 会把 ISO 时间字符串自动提升为 `DateTime`；对类型敏感的 JSON 读取用
  `-DateKind String` 或等价保形解析，不要放宽 schema。

## 参考

- Android 官方建议按动态 App 窗口而非设备型号适配：
  https://developer.android.com/develop/ui/views/layout/use-window-size-classes
- Android 16 在大屏上会忽略部分方向/宽高比/可调整大小限制，不能依靠锁竖屏规避适配：
  https://developer.android.com/develop/adaptive-apps/guides/app-orientation-aspect-ratio-resizability
- vivo 官方“应用多窗”说明：https://bbs.vivo.com.cn/newbbs/thread/32933113
- vivo Pad 官方产品页（“一个 App，双窗口高效浏览”）：https://www.vivo.com.cn/vivo/vivopad
