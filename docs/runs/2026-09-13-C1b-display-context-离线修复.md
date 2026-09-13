# C1b display context 回退的离线修复

## 问题与范围

固定候选 `c43652a9b16d9fa743e48332dea967d0c6d80ccb` 的一次授权设备尝试 r1 已失败封存。
独立 observer 观察 wrapper/runner 实际退出 1；reader 250 项确认失败记录，provider 返回
`capture_c1_display_unsupported`，c1 accepted 1、c2 accepted 0、无 committed token 或重采。
本轮已越过安装与 fresh T0 前置，但没有 c1/c2 通过结论。原始 run 为
`tl1-c1b-20260913t013327z-fb479afa3d25`，失败 JSON 的 SHA256 为
`0d5ebbf97ef4d57bc1b9146e9f36162f60d63a2f90341fe252c441c492ebdc2a`。
设备终态协调记录在 `codex/agent-workflow` 的文档提交 `ebc61c9`；旧候选及其证据不修改或重跑。

`AndroidTabletC1bSource` 先读取 `service.display`，只在 null 时回退到现有 `DisplayManager` 默认 display。
[Android Context.getDisplay 合同](https://developer.android.com/reference/android/content/Context#getDisplay())
明确：没有关联 display 的 context 可以抛出 `UnsupportedOperationException`，因此原 null 回退不可达。
该 API 合同缺口可以离线复现；设备 payload 只保留 display/unsupported 分类，没有调用点或异常栈，
所以本修复不宣称已经确定本轮设备异常的具体 API 或 ROM 根因。

## 修改

原生产文件内加入一个可用纯 JVM 验证的小函数，仅捕获 context display 读取的
`UnsupportedOperationException`，随后调用既有默认 display 回退；已有 display 直接返回。
Security、其他 context 异常、默认 display 获取异常与 metrics 异常仍向上传播。
回退不存在时仍失败；display ID、尺寸、方向、窗口一致性与能力门保持原规则。
没有增加生产输入文件、协议字段、采集请求、外部媒体或设备执行能力。

现有 `TabletC1bProbeTest` 新增 7 个回归用例，覆盖惰性回退、null/UOE、Security 与其他异常传播、
缺少默认 display、回退自身异常、原有 display/metrics 拒绝规则，以及失败不读取窗口和诊断脱敏。

## 验证与后续

使用固定 PowerShell 7.6.5 执行隔离 `tablet-c1b-probe` 模块的 Debug/Release JVM、两个变体 Lint 与
`verifyTabletC1bReadOnlyArtifact`，启用 offline、严格依赖验证、no-daemon 和最多 2 个 worker。
真实退出 0，106 个任务执行；每变体 6 个 suite / 87 项测试，0 failure/error/skip，合计 174 项。
两个变体 Lint 均无问题；只读产物证明门通过，没有新增 forbidden capability、manifest mutation 或组件。
两份独立静态审查未发现阻断；root 再次核对源码 diff 和测试 XML。

本地证据位于 `.checks/display-context-fallback/`：`dedicated-execution.json` 记录完整命令、实际退出和
两份源码输入 hash，1931 bytes，SHA256 `fb22024edc83ca717733a9126086842bcf5d54140262d348dccbbdacb3e9a9a7`；
`dedicated.log` 为 7384 bytes，SHA256 `3f4533801afd78cf72b1a20feac642ed4592058ff9c6b487408a2c25d48365b7`。
构建时本工作树尚未提交，所以产物中的 Git SHA 仍为基线 c43652a；验证绑定当前改动的 raw 输入，
不将产物冒充新的固定候选证据或原冻结 c43652a 的重新验收。

本分支仅完成离线代码修复和上述专项验证，未执行全项目完整门，没有新设备调用。
后续固定候选的完整验收、主机闭合和设备授权均须重新建立，不能复用旧候选的通过结论或本轮已消费的授权。
