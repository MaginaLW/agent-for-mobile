# 待办与有效决定

> 当前状态见 [STATUS](../STATUS.md)。本文只放待办和仍有效的决定；过程记录不进本文。
> 2026-11-15 精简前的全文用 `git show e1bae37:docs/backlog.md` 查看。

## 1. 下一轮任务安排

### 11 月 22 日攻关顺序

**A2 保留会话仍未产生新结构，B 的原版候选只在有资源名的正控取得四边，C 暂缓。** PA2553 最近一次免安装复核中，`2289925` 在请求四边前返回 `missing_id / before_sample / field_id_unresolved`。本轮用 API 36 合成靶检验两项独立条件。[真机复核与误选反例](knowledge/apps/wechat.md#横屏编辑框的四边能否单独确定输入目标)

| 工作包 | 本次结果或入场条件 | 剩余阻塞与验收 |
|---|---|---|
| A2 · 持焦切换后有没有新结构 | 空响应场已定位到客户端没有新的焦点进入通知。这次保留原自动填充会话，切换前后均为 `ACTIVE`，仍只有原请求 896。右框接到新连接的探针，14.099 秒观察期内没有新回调。靶应用显式请求数为 0。 | 同进程新 Activity 自然聚焦后取得新请求 898 和正确的右框四边。原请求 896 的采集早于新连接建立。[保留会话实测与正控](runs/fixtures/editor-autofill/retained-session/README.md) · [此前的焦点方法轨迹](runs/fixtures/editor-autofill/README.md#持焦切换时的客户端方法轨迹) |
| B · 候选权限下的窗口归属 | 原版候选 `2289925` 在有资源名的同包同类实例中返回窗 13、15 和相同的右框四边，均与靶应用独立读回一致。匿名两场都在采样前以 `missing_id / service_node_unnamed` 停止。普通权限观察在两窗读到了不同的无障碍窗号，但输入绑定标记、原生字段号及填充会话号均相同。 | 用已知目标窗号比对两份完整回执，宿主能双向排除错配。固定每个接收窗并只交换 IME 四边的来源假设，每个接收窗都有两个相容来源；候选未达到双向拒绝条件。[候选实测及双向回放](runs/fixtures/editor-autofill/window-replay/candidate-permissions/README.md) · [宿主诊断对照](runs/fixtures/editor-autofill/window-replay/system-source/README.md) |
| C · 真机只读诊断，依赖 A、B | 两包结果覆盖拟测起点后，准备能按指定会话只读取样、遵守应用排除设置的候选，再明确版本、服务变更、恢复范围及该轮授权。通过 `dispatch.ps1` 从已就位右窗核对微信是否实际提供结构。只保留身份比对结果、窗口号、四边、失败原因及收尾读回。 | 同轮核实唯一输入目标属于当前连接，来源窗口号与已核实右窗一致，完整矩形落在右窗内。缺项、冲突、目标排除即停，导航点击、输入、发送均为零。独立读回原输入法、启用清单、无障碍设置与原服务绑定、网关服务及转发。若另获准切换自动填充服务，连同原值一起读回。 |

`2289925` 与本地草稿 `ae93377` 的网关源码相同。候选声明无障碍服务和自有输入法，未声明自动填充服务。A2 所用的实验自动填充服务可以收取结构；B 用原版候选执行只读四边查询。[A2 实验服务](runs/fixtures/editor-autofill/retained-session/README.md) · [B 候选权限](runs/fixtures/editor-autofill/window-replay/candidate-permissions/README.md)

#### 补充实验收尾（2026-11-22 第二轮隔离 API 36 实测）

| 路线 | 实测结论（API 36 隔离模拟器） | 对 PA2553 微信的可用性与收尾 |
|---|---|---|
| **第四路线 · Pathway 4A+4B**（[PR #47](https://github.com/MaginaLW/agent-for-mobile/pull/47) `30dd179` + [PR #79](https://github.com/MaginaLW/agent-for-mobile/pull/79)–[#83](https://github.com/MaginaLW/agent-for-mobile/pull/83) `a3d272c` 已全部合入 `main`） | **API 36 隔离 `schema_version=2` 6/6 PASS + PA2553 起点 1（`36s`）、起点 3 桌面启动（`48s`）、获授权备稿 + ConfirmOverlay 发送投递全链、起点 2 左窗导航切入冷 `ChattingUI`（`a-000004` `ocr_reverify=exact_nav`）及冷 `ChattingUI` 底栏「可按住转文字」自动聚焦就位（`47s`，exit `0`，`a-000017` `ocr_reverify=exact_nav` → `inputType=0x24001` → `IME_CURSOR_ANCHOR` `[1048,1834,2578,1946]`）全部真机验通**（零新增权限、`AndroidManifest.xml` 与 `ConfirmOverlay` 未改动，全部轮次 4 项基线设置与双无障碍绑定双读回复原）。 | **已合入主线并实机闭环**：两段能力（左窗切入冷 `ChattingUI`、冷 `ChattingUI` 自动聚焦）均已在 `a90d86e`（`83cf0654...788b`）独立实测通过并经审计复核；单笔合流连跑「左窗 → 冷 `ChattingUI` → 聚焦右窗」为可选补验，竖屏 P0 独立暂缓。 |
| [输入法可见/零 UI 菜单 `ime-menu`](runs/fixtures/editor-autofill/ime-menu/README.md)（`a11ee7e`） | **4/4 PASS**（118.38 秒，8/8 设置读回）。`plain-auto` 证实零 UI IME 调用 `performContextMenuAction(android.R.id.autofill)` 可在异签名、未配合的匿名标准 `EditText` 上产出新鲜 `FLAG_MANUAL_REQUEST` 结构并精确匹配原生 `AutofillId.getViewId()`；`optout-no` 与 `swallow-ic` 均 fail-closed。 | **已验离线备选 1**（当前无需启用）：无需焦点变化或可见键盘，但仍需接管/恢复系统 `autofill_service`，且不单独解决同包多窗归属。 |
| [系统助理结构 `assistant-structure`](runs/fixtures/editor-autofill/assistant-structure/README.md)（`340dddc`） | **7/7 PASS**（511 秒，13/13 设置及 `android.app.role.ASSISTANT` 持有者均读回还原为原助理）。零 UI/零截图按需取得新鲜 `AssistStructure`，穿透微信式 `AccessibilityDelegate` 剥离并区分双窗/双 Activity 窗格，`FLAG_SECURE` 严格 fail-closed；实证 `ViewNode.getAutofillId() == null`。 | **已验离线备选 2**（当前无需启用）：可穿透无障碍剥离，但匿名框缺少跨通道 `AutofillId`，且需高侵入接管系统唯一 `ROLE_ASSISTANT` 角色。 |
| [逐请求矩阵与布局尺寸 `request-matrix`](runs/fixtures/editor-autofill/window-replay/request-matrix/README.md)（`2772db0`） | **4 核心 + 3 微信对抗全部实测收口**（145 秒，10/10 设置与双包读回还原）。显式正像素原生框通过活体双窗双向与同原点缩放区分，重合场 `ambiguous`；但 `match_parent`（`getLayoutSize()=[-1,-2]`）、`CODE_UNSUPPORTED` 与 `opaque`（`hidden_editors=1`）全部 fail-closed。 | **已收口为窄 AOSP 结论（不进真机）**：三项前提在真实微信上均已证伪，不再投入真机或模拟器槽位。 |

**PR #47（`30dd179`）与 PR #79–#83（`96c6d85`、`3c58d7d`、`39e2203`、`a90d86e`、`a3d272c`）已在 PA2553 真机完成全链闭环**：起点 1（已聚焦右窗，`36s`，exit `0`）、起点 3（桌面启动，`48s`，exit `0`）、获授权草稿备稿 + 单次设备端 ConfirmOverlay 批准发送与右窗消息区两行折行投递全链（`a-000039` `confirmation=allowed;decided_via=overlay;context=rechecked`）、起点 2 左窗点击「文件传输助手」切入冷 `ChattingUI`（`a90d86e` / `83cf0654...788b`，`a-000004` `ocr_reverify=exact_nav`，右窗 `win=418` 顶栏验证通过），以及冷 `ChattingUI` 经底栏唯一「可按住转文字」（`[1692,1874,1933,1909]`，`conf=0.58`）单次点击（`a-000017` `ocr_reverify=exact_nav`）唤醒 `inputType=0x24001` 并过 `Test-LandscapeEditorReceipt` + `Complete-LandscapePreparation`（`47s`，exit `0`，0 编辑/0 发送/0 确认卡；全部轮次 4 项基线设置与双无障碍绑定双读回完全复原）。两段均已独立实机闭环并经审计复核，单笔合流连跑「左窗 → 冷 `ChattingUI` → 聚焦右窗」为可选补验，标准竖屏 P0（`Allow`/`Stale`/`Deny`）继续独立暂缓。[左窗导航与冷启聚焦实测闭环](knowledge/apps/wechat.md#pa2553-起点-2-左窗导航与冷-chattingui-自动聚焦实测闭环) · [导航与发送规程](runbooks/P0-safety-hard-gate-smoke.md#横屏会话导航预演)

**派单传输与无障碍稳定性另行观察。** 11 月 17 日两次 HTTP 失败都缺网关结果。先复用派单离线用例核对「设备发现失败」「请求无返回」「网关返回失败」能否区分。下次已授权任务若重现，只核对同一时段的端口转发、网关健康与服务绑定，停在能证实的最后一层。小红书空白页也仅在自然复现时记下页面与是否有系统遮罩。[派单判读](knowledge/brain/harness.md) · [小红书记录](knowledge/apps/xiaohongshu.md)

### 已有验收与后续业务目标

11 月 18 日，PA2553 非微信三项均取得业务结果，首次派单且无现场协助完成的是 1/3，历史 M0 为 3/3。11 月 19 日，本地测试按钮的三项真人确认已完成。后续样本单独入账，保留这两次验收的原始结果。[非微信任务对照](runs/2026-11-18-PA2553非微信主验收.md) · [本地确认卡验收](runs/2026-11-19-PA2553本地确认卡验收.md)

11 月 19 日，小红书五条笔记和随任务的无障碍、启动观察均已完成。从本地测试 App 深链进入小红书后，执行器在同一派单中核对了查询词和五条笔记，无需现场协助。预检无须重绑，六份快照均未见系统遮罩。[本次验收](runs/2026-11-18-PA2553小红书只读验收.md#11-月-19-日单次无人协助搜索)

下一阶段先让执行器把平板带到测试起点。把设备检查、导航、输入焦点复核和收尾接入同一准备入口，复用 `dispatch.ps1`，避免每轮重写监督脚本。开跑前沿用已有授权，仅将缺少的事项一次列清，例如可处理哪条草稿、是否允许编辑栏局部图交给模型核对。上轮发送超时已收尾。下列是待验目标。

| 顺序 | 自动化工作 | 完成条件 |
|---|---|---|
| 1 · 设备与网关 | 复用派单预检和设备锁。先核对唯一授权设备、在机 APK 摘要及设置基线；版本匹配就沿用。由宿主处理唤醒、网关健康检查、必要转发与授权范围内的恢复。 | 在已解锁、已装匹配版本的 PA2553 上，从桌面启动准备，无需用户启动服务、重装或切换设置。停在锁屏、登录或厂商安装确认时，记录具体阻塞。收尾仅回收本轮资源并核对基线。 |
| 2 · 横屏会话与输入框 | 先从桌面或微信左侧列表自动导航到右窗；已在正确右窗时跳过导航。再解决空白编辑栏无法取得原生引用的问题。在本地测试页回放左右窗同名、焦点仍在左窗、键盘展开与收起，验证后再上平板。 | 在桌面和左窗两个起点分别取得右窗标题、活动焦点及同一会话的输入目标证据；已就位起点的导航点击为 0。空稿按授权写入一次，整行已是本轮测试串则复用，其他或无法辨认的草稿保留。就位后结束，发送调用为 0；误窗、识别不确定时编辑次数为 0。[导航预演与焦点验收](runbooks/P0-safety-hard-gate-smoke.md#横屏会话导航预演) |
| 3 · 现场发送与收尾 | 只在准备已核实、用户在场且本轮发送已获授权时请求一次；卡出现即提醒。若准备后隔了一段时间，执行器先重读焦点、整行和按钮。拒绝、超时或失效时结束。 | 正常路径上用户仅在平板决定一次。审计分别核对卡面决定、确认后目标复核、实际点击及测试串在右窗消息区的位置。最近两轮均在卡面超时，实际点击为零。标准竖屏 P0 的 Allow、Stale、Deny 另按原规程验收。[设备审计](knowledge/apps/wechat.md#保留草稿后的独立现场验收) · [标准 P0](runbooks/P0-safety-hard-gate-smoke.md#2-标准入口) |

到第 3 步可沿用已试过的提醒方式。由当次发送派单启动观察，每 2 秒检查一次窗口，最多 180 秒；发现卡、派单退出或连续两次读取失败即结束观察。只有发现卡时才提醒，卡面决定仍以设备审计为准。

第 1 步已在 PA2553 已聚焦右窗的起点验到零导航点击和自动回收服务、转发。第 2 步卡在编辑框识别。右窗标题匹配且键盘可见时，原生 `role=input` 返回 `E_NOT_FOUND`。Android 16 合成靶已分别核对活动输入连接的原点和可见四边。[真机回执](knowledge/apps/wechat.md#右窗编辑栏查找与自动收尾) · [合成实验](runs/fixtures/editor-origin/README.md)

11 月 21 日，PA2553 的资源名诊断已收尾。已签包声明了 `FLAG_REPORT_VIEW_IDS`，`123cf59` 从当次网关连接读到该位为真，两个字段候选仍都没有可用资源名。现有证据无法区分唯一编辑框。横屏自动就位和现场发送仍依赖能够独立核实输入目标及其右窗四边的新证据。标准竖屏 P0 的 Allow、Stale、Deny 保留为独立验收，按原规程核对竖屏空草稿、回车发送设置和当轮真人确认。[本轮真机证据](knowledge/apps/wechat.md#候选-123cf59-在资源名报告已开启时仍有两个无名节点) · [竖屏验收规程](runbooks/P0-safety-hard-gate-smoke.md#2-标准入口)

11 月 22 日，`2289925` 在已聚焦右窗取得 `missing_id / before_sample / field_id_unresolved`。真机回执没有编辑框矩形或候选数。同日，API 36 隔离模拟器中同一对控件轮流持有连接时，独立观察器均选对侧别与四边，两种歧义均返回空选择。实验使用专用输入法、自动填充服务及配合请求的原生控件，微信右窗的对应条件仍待核实。桌面和左窗两个起点验过后才排现场发送，竖屏 P0 独立暂缓。[真机回执与九组反例核对](knowledge/apps/wechat.md#横屏编辑框的四边能否单独确定输入目标) · [隔离环境四项实测](runs/fixtures/editor-autofill/README.md#隔离模拟器实测)

隔离实验已定位自然换框时缺少新结构的原因。左场空响应结束了会话，客户端已登记两个字段，随后明确忽略右框的自动进入事件。右框实际接手连接，系统新请求数为零。当前测试服务返回空响应时，不能依赖切换焦点重新取得四边，也不能沿用左框数据。微信右窗仍缺独立归属证据。[框架分段实测](runs/fixtures/editor-autofill/README.md#空响应后的会话与右框请求)

下一次汇报按起点列出准备耗时、首次派单能否就位、用户为导航或调试实际动手几次、是否出现确认卡及其决定。现场业务决定单独计数。卡前阻塞只汇总一次，写清停在哪一步、自动完成了哪些步骤，以及是否确有一项操作只能由用户完成。

### 横屏诊断收尾后的离线复核（11 月 21 日）

Android 16 合成实验补验了焦点事件。四次目标聚焦均收到来源相符的事件。同一无名框保持焦点并成功重建输入连接后，1,244 毫秒内该应用的焦点事件数为零。仅凭最近一次事件仍无法判定当前连接。横屏识别继续阻塞，本轮真机调用为零。[焦点事件与输入连接重启对照](knowledge/apps/wechat.md#无名编辑框保持焦点时重启输入连接)

在主线 `a4af974` 上复跑横屏任务卡的 `-DryRun`、浏览器合成页和宿主编辑框回执检查。页面上，左窗同名时先停，导航一次后才聚焦右窗；从正确右窗开始时导航零次。键盘展开后重新核对四边，双框、缺框、语音态或标题不符均停止，已有草稿保留，编辑与发送回调均为零。宿主的 3 个有效回执均通过，17 个异常回执均被拒绝。真实桌面启动和从微信左窗自动就位仍待验；现有资料无法唯一识别右窗编辑框，横屏现场发送继续等待，竖屏 P0 单独暂缓。[导航预演与回放](runbooks/P0-safety-hard-gate-smoke.md#横屏会话导航预演) · [无名候选的判读](knowledge/apps/wechat.md#怎样判读两个无名候选)

在 `d26e291` 上另用合成派单记录核对了动作后的就位判定。启动微信或点击后，宿主均须重新读齐前台、标题、键盘和编辑框。两条读齐的记录均通过；逐项省略一个新读数的八条记录均被拒绝，即使动作前已有完整读数。桌面启动、左窗导航和真实编辑框的效果仍待现场证据。

| PR | 处置结果 | 核实依据 |
|---|---|---|
| [#40](https://github.com/MaginaLW/agent-for-mobile/pull/40) `908a454` | 已关闭，原点诊断由 #47 承接。 | `e994c71`、`cf4b6a9` 均在 #47 的历史中，原点诊断测试逐字一致。 |
| [#45](https://github.com/MaginaLW/agent-for-mobile/pull/45) `83f9653` | 六个实验文件已单独合入 `main`（`d26e291`）。 | 全新 API 36 模拟器上，延后样本与系统焦点两组均为 4/4。第四行四边一致且返回 `missing_id` 时通过；独立反例仅将无障碍右边界偏移 1 像素，仍返回 `missing_id`，该行失败。[复现说明](runs/fixtures/editor-origin/README.md#用当前输入焦点核对身份和四边) |
| [#47](https://github.com/MaginaLW/agent-for-mobile/pull/47) `3d700cc` | 已合入 `main`（`30dd179`）。 | `IME_CURSOR_ANCHOR` 生产接线 + 宿主回执分支 2 通过 `check.ps1` 9/9、API 36 `schema_version=2` 6/6 与 PA2553 起点 1 官方横屏就位实测（`36s`，exit `0`，0 点击/发送，4 项设置与双无障碍绑定双读回复原）。[实测记录](knowledge/apps/wechat.md#pa2553-起点-1已聚焦右窗生产横屏就位实测通过) |
| [#73](https://github.com/MaginaLW/agent-for-mobile/pull/73) | 横屏双框归属的隔离实验已收尾，交付靶应用、观察器和复现记录。 | 手动请求下左右框均选对，四边重合与焦点冲突均停止。自然换框时右连接接手，系统新结构请求为零，客户端日志已定位忽略进入事件的原因。[实测记录](runs/fixtures/editor-autofill/README.md#空响应后的会话与右框请求) |
| [#79](https://github.com/MaginaLW/agent-for-mobile/pull/79) `96c6d85` | 已合入 `main`。 | `resolveOcr` `<60px` 裁区受控 2x 放大兜底 + 任务卡第 3 步左窗 OCR 引用说明（保持 `0.65f` 不变）。 |
| [#80](https://github.com/MaginaLW/agent-for-mobile/pull/80) `3c58d7d` | 已合入 `main`。 | 大屏 `SAME_APP_MULTI` 分窗 1:1 切片 OCR（`OcrTilePlanner`）与逐窗稀疏判定，恢复 PA2553 左窗稳定命中。 |
| [#81](https://github.com/MaginaLW/agent-for-mobile/pull/81) `39e2203` | 已合入 `main`。 | 方案 A `ocr_reverify=exact_nav`（仅普通 4+ 字导航点击双帧精确复核；危险/短标签/非点击保持 `0.65f` 与 `ConfirmOverlay` 不变）。 |
| [#82](https://github.com/MaginaLW/agent-for-mobile/pull/82) `a90d86e` | 已合入 `main`。 | 2,334 对 `TraditionalToSimplified`（根治 ML Kit `输↔輸`/`横↔橫` 抖动）+ `SafetyPolicy` 繁体危险词防护 + `appWindowElementCap` 多窗防饿死；PA2553 实机 `83cf0654...788b` 经 `a-000004` `ocr_reverify=exact_nav` 点开冷 `ChattingUI`（`win=418`）。 |
| [#83](https://github.com/MaginaLW/agent-for-mobile/pull/83) `a3d272c` | 已合入 `main`。 | 冷 `ChattingUI` `input_type_null` 白名单单次点击右窗底 1/5「可按住转文字」+ 点后重读校验；零 APK 重编，PA2553 实机 `a-000017` `ocr_reverify=exact_nav` 唤醒 `inputType=0x24001` 并过 `Test-LandscapeEditorReceipt`（`47s`，exit `0`）。[闭环记录](knowledge/apps/wechat.md#pa2553-起点-2-左窗导航与冷-chattingui-自动聚焦实测闭环) |

## 2. 按需再做（有具体任务需要时才排）

- M1b 占位工具：通知读取/回复、`ui_diff`、Shizuku 强停当前已从 `tools/list` 下架；按需实施与必验失败路径见 [能力现状](knowledge/android/m1b-capabilities.md)。
- 语义意图生产接线：基础模块已在代码中，接线范围见 [语义意图 spec §5](specs/2026-08-02-语义意图审批-design.md)。
- 分享落地 activity 白名单：必须来自真机观测，没有观测就保持空。
- 微信相关任务（M0-2/M0-4 发消息、发图）：已后置；重启后以「三层窗口 + 点右窗发送按钮确认卡」单独实测，仍参考 [平板知识](knowledge/android/tablet.md) 与 [微信知识](knowledge/apps/wechat.md)，不恢复已删除的研究栈。
- M3：宏系统「教一遍」、语音/分享入口、App 技能包。

## 3. 有效决定

| 决定 | 内容 |
|---|---|
| 设备基线与三层窗口 | vivo PA2553 / Android 16。项目适配设备，不禁用 `com.vivo.safecenter` 或关闭系统多窗；支持单窗口与同应用平行视界（分屏/跨应用/未知多窗严格 fail-closed）。手机真机验收暂停。 |
| 大脑与派单 | 只用 Codex CLI 官方登录（固定 `codex + gateway`）；优先使用受控 `toolchain/codex` 冻结副本，回退官方桌面目录；预检内建网关自启、token 同步（仅 debug 可读写）与非设置页单次无障碍重绑。 |
| 点击与常规回车规则 | 普通具名点击（有可读 text/desc 且未命中危险/动作确认/发送/敏感词表）直接放行+审计；纯图标无标签或命中词表弹确认卡；`sensitive_targets` 与黑名单目标出站直接 `E_BLOCKED`。常规 `press_key(enter)` 只要 `focusIdentity + inputCommitEvidence` 齐全即可进确认卡（无会话标题时卡面明示；同应用多窗且 `IME_ONLY` 拦截）。 |
| 危险动作 | 发送/支付/删除类两段式：网关在执行前弹出设备端确认卡（ConfirmOverlay，默认超时 90s），由现场真人批准；一次批准只放行当次调用。通知只能拒绝或查看，不能批准。 |
| 风险分级 | 两档都逐次确认，没有免确认路径。见 [风险分级](specs/2026-08-01-危险动作风险分级-design.md)。 |
| 安全失败即终态 | 拒绝、超时、上下文失效后不重弹、不换路重试。 |
| PC 输入不是批准 | 终端输入（`Read-Host`、`RESUME` 等）不能当危险动作的真人批准；`-Confirm` 只恢复未调用危险工具的前置步骤。见 [执行 harness spec §5](specs/2026-07-17-执行harness-design.md)。 |
| `intent_send` 落地 | 指定目标时落地失败返回 `E_VERIFY_FAIL`；未指定目标如实报告“已分派、未验证”。 |
| 语义意图时钟 | `ConfirmOverlay` 默认超时已生效为 `90s`；语义意图 `intentTtl 360s` / II 级 `foregroundWaitBudget 300s`（I 级 0）/ 证据 TTL `120s` 尚未完成生产接线，见 [语义意图 spec](specs/2026-08-02-语义意图审批-design.md)。 |
| 会话标题读取 | 标题识别放在生产代码，宏复用同一份；不另造弱读取器。 |
| 宿主进程 | 脚本不终止外部进程；PC Suite 等占用 ADB 5037 造成冲突时由用户处理。 |
| 安装等待 | 安装命令不设自动超时（现场确认可能慢），开始前提醒用户。 |

## 4. 怎么做

- 改代码后按 [离线开发与验证](runbooks/离线开发与验证.md) 跑 `scripts/check.ps1`；只改文档或脚本时用 `-SkipGradle`。
- 真机运行记下构建的 commit SHA、设备和结果；失败保留证据，查清原因再跑，不盲目重试。
- 一次运行写一行台账（`dispatch.ps1` 自动写 `docs/runs/ledger.csv`）；只有出现新结论或新坑时才写 `docs/runs/` 记录，可复用的经验写进 `docs/knowledge/`。
