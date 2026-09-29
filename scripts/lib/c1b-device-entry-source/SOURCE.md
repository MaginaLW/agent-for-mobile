# C1b 设备入口维护源

本目录是受版本控制的参数模板。`../c1b-device-entry-source.ps1` 只定义生成、只读审查和主机发布函数；`../../prepare-c1b-device-entry-source.ps1` 只产生审查材料。准备、源码发布、binding 和 Ready 均不授权设备操作。

模板固定为 UTF-8、无 BOM、LF。生成物同样使用 LF；原始 SHA256 和字节长度均按实际文件计算，不把 Git blob hash、历史 CRLF hash 或 Parser 通过当作原始字节证明。

生成输入必须绑定当前完整 SHA、普通 clone 的 HEAD/ref/index、六项 Git 元数据、42 项实际实现原始 hash/catalog、钉定运行时，以及 20 个模板、五个依赖和 strict verifier 的实际 raw pin。绝对路径仅进入 ignored 运行材料；模板中保留参数槽。路径槽用 PowerShell 单引号转义，禁止 CRLF、NUL 和未归一化路径。

生成顺序保留九个入口、五个辅助、support auditor 和五个 reviewer/capture。prepare 输出 `source-manifest.json` 和 20 份 readonly 审查源码，最终 entry root 单独指定。它不调用任何生成物，也不发布 Ready。

主机链必须串行消费以下证据：

1. 当前 A1 authority 与 42 项 raw inputs，形成 deterministic manifest；机械 reviewer 重新生成并逐字节核对，不作独立语义通过声明。
2. 独立 `c1b-device-entry-source-review/v1`，必须绑定当前 candidate、manifest、全部 source/output pins，P0/P1 为空并记录实际语义审查依据。
3. 从 review directory 调用经 pin 的 source publication capture/outer capture。publisher 只用 CreateNew 写最终 readonly 来源，目标已存在即拒绝；失败留下材料，不重用目录。
4. support auditor 消费真实 inner/outer capture 的单独 stdout/stderr EOF、原始 execution/reservation、actual exit、cleanup、publisher argv、actual stdout 与最终输出 pins。`entry-capture.json` 和四份原始文件必须属于同一目录、使用固定 leaf 且目录仅包含这五项；reservation 与实际 capture 的时间和 parent PID 相符。capture source、runtime 和实际 argv 分别绑定当前 raw pin。所有验收布尔量和计数必须是真实 JSON bool 或 int/long。根调用方仍须独立观察两个 capture 的退出码。
5. binding 重新消费 support 和 `c1b-host-device-entry-acceptance/v1`，验证当前原始主机证据、外部 BuildOnly tuple、Git authority、独立源码审查，独占创建 `<candidate7>/r1/binding.json`。
6. prefix capture 执行 observer 的八条只读启动语句和 native 自观察定义，禁止 formal reservation、UAC、wrapper、ADB 或设备调用。
7. Ready 再消费 support、当前 host acceptance、actual binding/prefix captures、prefix 结果原始字节加 CRLF 的 stdout、完整 EOF/cleanup 和未消费的 receipt root。Ready 保留场景未测量、设备未执行、重新确认必需的边界。

任何 runtime PID、native exit、时间、source review 或最终契约 hash 都是当前必填输入，没有历史默认值。capture 从当前 manifest 选择源码，只接受正式目标或同一 manifest 的审查目录中完全相同的来源，不能凭 leaf 名和 caller 提供 hash 执行任意文件。

正式设备 capture 仍要求新的 `c1b-device-scene-user-confirmation/v1`，绑定 readonly binding 和 Ready，记录当前用户消息并保留 `scene_measured_by_runner=false`、`device_evidence_verified=false`、`automatic_retry_authorized=false`。observer 保留 native held wrapper/child identity、唯一直接子进程、真实终止后的 native exit、独占 observation、禁止自动重试和 kill。wrapper 不声称独立执行 binding 校验。

终态 reader 从实际 runner stdout 的唯一 failure-reference JSON、成功 sidecar 指针及所有 checkpoint 指针选择原始证据。时间只用于核验，不用于目录扫描或选择。R3 context 首先安装已 pin 的 native authority；reader 保留原来的成功九产物、private read-only proof 和 cross-binding 校验，之后调用 `Get-C1bTerminalDiscoveryIdentity` 输出 verified/unavailable。未知内部 AttemptId 或 run promotion 不允许 Freeze；`r1` 不是内部 AttemptId。正式 Read/Freeze 由 tracked `read-c1b-terminal-discovery.ps1` 独立再消费 observer/terminal/binding，保留 one-shot marker。

host acceptance 的 `SummaryVerifierContext` 只在维护库已经从当前 held strict 原始字节唯一初始化 native type 时构造。consumer 独立复核该 raw pin/byte[]，在 private module 中仅安装已核对的函数定义；默认 consumer 继续拒绝来源不明的预加载 native type。这不是 JSON 授权开关。正式 binding/Ready 各自在钉定的冷 CLI 子进程中导入 host acceptance 一次；同进程重复导入该 native authority 继续拒绝，组合夹具不声称这种互通已通过。

安全控制流的迁移基线为 `a878d1216e6f04341c82377c64eb0eb162f048ed` 的已审入口原始来源。以下原始 pin 是来源追溯，绝不作为未来候选或执行授权：

| 保留控制流的模板 | 原始字节数 | 原始 SHA256 |
| --- | ---: | --- |
| invoke-next-device-once-r1 | 5652 | c7448d22b67768487290ab5f9fd2850b0fe9c377b351dddb04b36b69bba38e62 |
| observe-next-device-launch-r1 | 18497 | f0eb2d59223999d07c45a83a46caa03ebe43b4f6185feecf532a4531cdcae5d0 |
| verify-next-device-terminal-r1 | 20564 | 833e581167c9e27127c4ab4603141513622c8754b2a8c6342aa2c1e401babafc |
| preflight-device-observer-r1 | 9844 | 37a1588730d120e2428eaadadae003cfba1cddbff3ebb582eb55ab85471e05c7 |
| capture-device-observer-r1 | 14296 | 3f88af045e47bc63432e6a4b84890d2bd3531194cd690d25d7704eabc3e076c3 |

binding、Ready、source publication、support 和 host captures 已按当前 tracked consumer 重建；不能对这些语义变化声称 function bodies unchanged。独立审查需覆盖实际新来源及全部生成 raw pin，并区分 Git canonical LF 与历史普通 clone 的实际 CRLF。

全部模板固定 UTF-8 控制台输出，保证冷 CLI 的中文路径能被严格原始字节消费者读回。

离线专项：`scripts/tests/c1b-device-entry-source-offline.ps1`。真实 native 文件夹具验证 deny-write、readonly、current HEAD/ref/raw inputs、deterministic publication、replay 和 EOF/cleanup；binding/Ready 组合夹具明确只 stub host acceptance，完整 host consumer 由独立专项验证。测试另执行一次合成仓库内的已渲染机械 reviewer 冷进程，核对中文路径的原始 UTF-8 stdout；不执行设备入口、launcher、build、ADB 或 provider。
