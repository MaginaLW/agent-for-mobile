# 项目状态

> 更新 2026-11-05（固定 abb7b0d 真机两帧均收齐 5 项、丢弃 0；未知 -1 已保留，类型/语义/IME 仍阻塞，T-L1 未通过）。本页只写现在在哪、卡在哪、下一步；待办、需要用户的事项和有效决定见 [backlog](docs/backlog.md)，过程证据见 docs/runs/。精简前全文用 git show aa126dd:STATUS.md 查看，更早历史见[状态归档](docs/status-archive.md)。

## 一句话现状

固定 `abb7b0d9ca99034e4e7886694fdd96c58082985c` 的同签名包 `f4444fc0…2a6db4a` 已经独立后验确认并完成一次 v3/inner-v2 真机采集。两帧均输入/尝试/保存=5/5/5、丢弃=0、12 类首停全零、拒绝表为空，windows_truncated=false；原 -1 壳以 unknown 保存，root package=android/readable/exact，但不证明它的角色或可忽略。微信树仍 opaque，IME unknown，原清单截断 blocker 被 window_type_invalid 替换，T-L1/P0/execution 未通过。见[本轮记录](docs/runs/2026-11-05-未分类窗口真机验收.md)。

前轮 `156dbde` 每帧丢弃一次 -1，是本次修复输入，不用新结果回填。新代码既有完整离线门 16/16、修复专项和固定产物补验复用；C0 真机源固定 abb7b0d。C 停止后另按用户明确要求改标准 runner 的安装等待为无自动超时，离线 5/5、独审通过；此 host 增量未用于 C0，不称再次真机安装。

前轮固定 `597ca8b713456cbfe82aa84af3abdcb7c19e1c79` 的后验与一次 C1b 已通过当时封套/原文/计数合同：两帧输入 5 / 保存 4 / 丢弃 1，唯一首次停止 `window_type_invalid`，精确值及窗口身份未记录，不用新轮回填。见[前轮记录](docs/runs/2026-11-04-诊断后验与窗口采集.md)。旧安装卡及 f983/565/e673/51fe 原轮保持冻结；手机 C 道与批次 4 继续暂停，当前诊断分支未合 main。

## 需要用户做的

A07 签名、A08 安装原轮与 A09 独立后验/采集许可均已消费，C 已停止；无需继续保持双窗、重进设置、重装或切权限。安装前继续用 ask 提醒；今后安装等待不设置自动超时，累计读预算不包含安装等待。新设备工作仍按 [backlog §7.3](docs/backlog.md#73-开跑条件)核定。

A08 安装在 60 秒 native timeout 冻结（8 次 SDK、锁释放，效果当时未知），未续跑；另获 A09 许可后 11 读确认新 f444 包及两点 enabled/ready，再采一次，未重装。独立后验不改判原安装，不证明持续绑定、数据全量保留或 provider 清理。旧安装卡也保持原冻结。

用户已采纳 A10 窄补充：未来可事先在报告和许可中单独覆盖“仅安装超时/效果未知”后的有限独立后验及条件采集；原安装仍冻结，规则不是未来运行许可，也不追溯 A08。有限阶段链已覆盖的成功前置不逐段询问。厂商邮件尚无技术答复，不重复发信。

## 下一步

- 根据已收齐的 5 项壳数据，核定 unknown 类型/IME 与 window/pane 视觉来源的安全边界；root package=android 不能替代角色证明，不猜映射或忽略该窗。
- 图像来源范围审查已完成：现有 lifecycle 仅输出元数据，C1b APK 明确禁止截图能力；未来需独立核定隔离制品、端侧展示与隐私范围。完整 inventory、pane/几何/同代仍是前置，不创建图像运行卡或新批次。见[本轮复审](docs/runs/2026-11-04-诊断后验与窗口采集.md#图像来源范围复审)。
- 未分类窗口新代码留在 `codex/c1b-unknown-types`，尚未真机验收，不合 main。已验 `156dbde` 与历史 `597ca8b` 按原版本保留；旧原字节传输候选 `ccc8cce` 已在 main。
- 安全离线候选 `dc13f1c233c8a1ef0feb40aa9b04c6c2f1bf55ae` 保持隔离，既有完整门 14/14 不等于真机验收。R1 原入口阻断已受控验收；R5 独立来源及实际验证窗口仍未成立，不新增任务卡；P0、T-L2 与手机批次 4 保留原门禁。具体队列见 [backlog](docs/backlog.md)。

## 里程碑

| 里程碑 | 状态 |
|---|---|
| M0 mobile-mcp 真机验收 | 完成（2026-07-16，4.5/5） |
| M1 自研网关 | 已在历史手机上跑通。P0 两段式硬门未闭合：批次 1–3 已验收；现行链路下 Allow、Stale 尚未独立真机验收（见 [P0 规程](docs/runbooks/P0-safety-hard-gate-smoke.md)）；语义意图四腿（批次 4）暂停 0/4 |
| M1-T 平板适配 | T0-L 完成；C1a origin/read-only 成立；C1b abb7b0d 的 v3 真机收齐 5 项/帧，unknown/语义/IME 仍阻塞，T-L1 未通过；T-L2 未入队 |
| M2 大脑迁到手机 | 未开始 |
| M3 宏、入口与技能包 | 未开始 |

## C1b 卡点详情

- 退役理由：按运行记录近似统计，自 08-28 起约 20 余个固定候选都没有闭合 Ready 和设备验收，09-13 后都停在主机阶段。最后候选 r13 `8d808b1` 因宿主 ADB 边界非空失败，未到构建。
- 旧链最后设备轮为 09-13：`a878d12` 识别到 0 台设备，`c43652a` 报 display unsupported，根因未知。新 runner 已于 [10-09 首次真机尝试](docs/runs/2026-10-09-C1b-真机-vivo安全中心撤销无障碍.md)发现唯一设备并完成构建、安装；无障碍权限被撤销，采集未执行，显示回退仍未验证。
- 11-01 的 51fe/e673 轮在 T0 absent 冻结；565 的复合锚点失败字段未定，f983 首失配 upstream_t0.artifact_sha256，不能回填旧轮。ccc8cce 新轮有效 observation 已保存，原 T0 绑定通过；window_inventory_truncated、semantic_subtree_opaque、ime_inventory_invalid 等七项 blocker 保留，显示回退未单独验证，provider 清理仍无独立证明。见[原字节传输验收](docs/runs/2026-11-01-C1b原字节传输候选验收.md)。
- 11-04 新诊断轮确认每帧完整枚举 5 项、尝试 5、保存 4、类型有效性门丢弃 1；该项的后续 display/layer/几何/焦点/id/root 未读取。保存的两个微信 root 各仅一个退化不可见节点、child_count=0，语义 opaque。IME 的 visible=false 不足以覆盖 mode/binding unknown，七项 blocker 保留。
- 新流程保留只读边界、固定完整 HEAD、全局设备锁与每轮开跑令；旧 once、UAC 与主机候选冻结链已退役。失败仍保留本轮证据，不自动重试；新一轮按 [C1b 规程](docs/runbooks/T-L1-tablet-c1b.md)重新就位。

## 暂停与后置

手机批次 4、语义意图生产接线、T-L2/T-L3/T-P、M1b 占位工具实现均暂停或后置，条件见 [backlog §4–§5](docs/backlog.md)。

## 代码分布

2026-10-13 按用户“合入”指令，main 已整合协调分支 `codex/agent-workflow@bb3deb0`（含去复杂度收尾及 R1/R4/R5/C1b），并保留原 `origin/main@8bc0c87` 文档历史；全量离线门 13/13 通过。10-14 按用户“可推送的推一下”指令，已将 `7bf9fb4` 普通快进推送至 origin/main，并回读完整 SHA 确认。C1b 实现线的 app 修复已于 `cc74daf` 取入，`cad7411` 不再有独有 app 改动。R1/R5/C1b 仍未完成真机验收，手机批次 4 候选未合入；本次源码整合与推送不放行设备运行。见[主线整合与推送记录](docs/runs/2026-10-13-本地主线整合.md)。

10-18 main 新增冻结规程修复及扫描修复 `a2cbfdb`，修复与首批收尾记录已按用户“推送”指令普通快进推至 origin/main，落点 `69d2953` 的完整 SHA 回读匹配；随后仅同步状态，代码不变。最终本地、远端均仅保留 main，剩余九条旧远端分支已转三个归档标签；仅本地 `archive/batch4-precheck-unify` 仍指向原候选 `67ef56c`，暂停 0/4、未合 main。
