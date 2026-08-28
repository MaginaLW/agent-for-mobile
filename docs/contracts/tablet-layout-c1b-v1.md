# Tablet T-L1 C1b v1：受控只读运行合同

## 边界

C1b v1 只运行 `tablet-layout-observation/c1b-v1` 的 pure-a11y producer。它不调用 ToolRegistry/MCP，
不执行 action/gesture/input，不改 settings，不启动目标 App，不截图、不 OCR、不写 raw UI 内容。

运行前必须完成 A 道离线门、专用 probe 的 Debug/Release artifact proof、gateway 生产面 release absence 与独立
审查，随后固定完整、clean 的 `HEAD`。C 道需要用户针对该 SHA 的新授权；C1a 的授权不可复用。runner 只接受
绝对 ordinary `adb` 路径和显式 `-Provision`，恰好执行一次
fresh controlled build、一次 `install -r -t`，不卸载也不自动重试。runner 恰好请求 `c1`、`c2` 两帧，宿主间隔
至少 900ms，总 capture span 不超过 15 秒，不补拍。

A 道公共入口 `scripts/run-tablet-layout-observation-c1b-v1-offline-gate.ps1` 必须将本次 fresh gate run id、
exact case/coverage、Kotlin direct-focus 跨层 requirement 与永久 false/unsupported 安全结论原子写入固定
`.checks/tablet-tl1-c1b-v1-offline-gate.summary.json`；consumer 只接受本次 run id 且两分钟内完成的摘要。

宿主 runner 的独立 fake-ADB 门是 `scripts/run-tablet-layout-c1b-offline-gate.ps1`，固定输出
`.checks/tablet-tl1-c1b-host-v1-offline-gate.summary.json`。其 summary 是 closed、单行 strict JSON，绑定 fresh
gate run id、两分钟 freshness/span、26 个 exact coverage、`fake_adb=true`、`real_adb_call_count=0`，并固定所有
runtime/layout/action 结论为 false/unsupported；不能把旧摘要、删减 coverage 或自报成功当作门通过。
完整 synthetic runner E2E 的 5 个场景已最终稳定复跑通过：fake ADB total 219 = valid 211 + rejected 8；
valid 由 private server start/status/kill 6/6/4 与 device calls 195 构成，T0 calls 4 是 device 子集，另观测
server exit 6。runner process 7、fake Gradle 6、fake signer 10、repository inputs 41，real ADB/JDK/Gradle
executions 全为 0。direct client Job active limit 固定为 1，T0 四层 Job 链 limit 固定为 4；两次
official-style auto-start attempts 均未逃逸，escaped child/listener/side-effect 为 0，正常 cleanup 无锁、
listener、server、build-root 等残留。这些计数只证明 host orchestration，没有执行真实 JDK/Gradle build 或
访问平板。专项门为 build-env 23/23、artifact 32/32、ADB provenance 6/6、private ADB 16/16、T0 sidecar
7/7、aapt2 15/15、readonly 67/67。

## 构建与宿主信任闭包

runner 从 fixed HEAD 的实现表导出 exact 41 个 repository input（新增 private ADB server module），按 ordinal
`relative/path=sha256:<lowerhex>`、UTF-8 无 BOM、LF join 且无尾 LF 形成 catalog；sidecar 必须保存
`repository_inputs.file_count=41` 与针对该 HEAD 重算的 `catalog_sha256`。catalog hash 是 HEAD 绑定值，
不得从 fixture 或旧 run 复制。

build-environment guard 固定以下 filesystem-and-environment 输入：

- Oracle JDK 21.0.5 完整 418-file tree；
- Gradle 8.9 `distributionSha256Sum` 与完整 299-file tree，wrapper 不执行，由 held Java 直接进入
  `org.gradle.launcher.GradleMain`；同一 held Java 直接进入 `ApkSignerTool`；
- Windows Program Files KnownFolder 下的 canonical 完整 `Git` 安装树，且 `cmd/git.exe` 签名有效：9,576 paths、9,489 file
  identities、85 个内部 hardlink groups，full-tree catalog 固定为
  `sha256:4c5e585b10f371f181b42b60948a883409c0efda910b869ff98c2e5604267458`；另绑定
  `cmd/git.exe`、两处 `mingw64` Git、`libcurl`、`libssl`、`libcrypto` 共 6 个关键文件 hash。只冻结入口
  executable 不足以通过；
- Android SDK `build-tools/35.0.0`、`platforms/android-35` 与 `platform-tools` 三棵 source package tree，
  再复制为仅含这三包的 11,348-file isolated SDK，catalog SHA-256 固定为
  `sha256:09a7cb46fef3c2b505330e4dfa09abbe4ba739412e8450e97b3458ddbaf473d8`；
- fresh Gradle user home、`user.home`、project/Kotlin cache、process temp、module build output 与固定 debug
  keystore copy；仓库 `local.properties` 必须为空，隐式 `buildSrc/build-logic` 必须不存在；
- source/input tree 的 file deny-write/delete、directory ACL/identity guards、recovery journal，以及同一 Windows
  logon session 内覆盖全部 C1b build 的全局互斥。

构建允许联网，不得传 `--offline`；依赖仍必须由 `--dependency-verification=strict`、固定 verification
metadata、artifact allowlist/hash、fresh caches、no build/configuration cache、rerun 与 no-daemon 共同约束。
专用 `:tablet-c1b-probe` 必须同时产生 Debug APK、Release unsigned APK 与
`tablet-c1b-read-only-artifact-proof/v1`。宿主独立复核 proof 的 exact 12-file source allowlist、11-file build-input
allowlist、dependency catalog、Debug/Release merged manifest、packaged manifest/a11y XML exact tree、连续编号 DEX
entries/catalog，以及受信 aapt2 binding；不能用 gateway legacy APK 代替。

Git child process 必须传 exact 15-key controlled environment 与 `ClearEnvironment`，禁用 system/global config
并使用 minimal `PATH`；Gradle/apksigner、ADB、aapt2 与 T0 的所有 child process 也必须传各自显式受控
environment 与 `ClearEnvironment`。Windows host paths 来自系统 API；全局 device lease path 只来自 Windows KnownFolder API，
不能信任 `LOCALAPPDATA`。T0 sidecar 必须用 lease token 加入 runner 已持有的同一锁。

sidecar 的 `threat_boundary` 必须 exact 为：

```text
filesystem-and-environment integrity after guard establishment; excludes same-user process-memory injection, pre-existing writable handles/mappings, ACL/ownership takeover, and same-user concurrent mutation of all intentionally writable fresh build working state (including dependency/project/Kotlin caches, process temp, Gradle daemon/native/transform state, and module outputs) during Gradle execution and the post-exit-to-final-guard window
```

`host_launcher_cmd_not_executed` 与 direct-Java 主张只适用于 runner 直接启动的
`GradleMain`/`ApkSignerTool`，不外推到 T0、ADB、aapt2 或 descendant process。

## 宿主—provider 协议

CLI 输入的 source `ANDROID_SDK_ROOT=ANDROID_HOME` 必须 ordinary、非 reparse，`-AdbPath` 必须 exact 指向其
`platform-tools/adb.exe`；任意 SDK 外 executable 即使可模拟 ADB 也必须在 build/install 前拒绝。guard 建立后，
runner 将 Android child roots 与实际 adb/aapt2 重绑到 isolated SDK，并在 `49152..65535` 随机选择 loopback
port，以 `server nodaemon` 建立本 run 专用 ADB server。全部设备命令必须显式传 `-H 127.0.0.1` 与
`-P <private-port>`，且 controlled environment exact 设置 `ADB_SERVER_SOCKET=tcp:127.0.0.1:<private-port>`；default
5037 不得监听、连接或作为 fallback。runner 必须闭合 private listener owner PID、`server-status` executable、
Windows job membership、server process identity，以及 cleanup 后 listener absent + 同 port rebind 成功。runner 在
采集前后及 sidecar 发布前校验 `adb version` identity、Installed-as isolated canonical path、executable hash 与
exact version-output hash，并把这些闭合字段写入 sidecar。authority 固定为 `dev.magina.gateway.tablet.c1b`，端点仅允许 `t0/status/capture/c1/capture/c2/result/abort` 的
canonical URI。`t0` 必须通过 `adb exec-in content write` 原样转发 fresh T0 v5 的 exact bytes；宿主同时绑定原始
受控路径、SHA-256、byte count、CRLF count，并要求 provider 回显 expected title hash、producer full SHA、
producer artifact SHA、embedded HEAD、build challenge 与 generation。其余端点只用 `content read`。

第一次 status 必须是 `ready_c1`。`c1` 与 `c2` 各只请求一次；异步状态只允许
`capturing_c1 -> ready_c2` 与 `capturing_c2 -> complete`，使用 bounded poll。每一次中间及 terminal poll 都必须校验
`ok/next/reason`、generation、accepted counters、committed-token prefix、in-flight token 与零 recapture 的完整 exact tuple，
任一漂移都立即失败，不能等待后一条正常 terminal 覆盖。`result` 只读一次。成功前再次固定唯一设备 serial hash、
fingerprint hash、boot-id hash、package/version、installed base.apk path/hash、local APK hash 与 signer；失败后的 abort
至多尝试一次，abort/cleanup 不触发采集。仅当 `result` 的 exact bytes 已被严格识别为 observation，并通过 schema、
validator、T0/provider/device/APK 与冻结实现绑定后，宿主才可标记 session consumed；`result` 返回 control、畸形 JSON
或上述任一验证失败时必须保持未消费状态，并在 finally 中进行唯一一次幂等 abort。abort 只接受闭合的
`aborted/failed/expired/absent` terminal control：`ok=false`、`next=none`、reason 白名单、无 in-flight、零 recapture；
非 absent terminal 的 generation/counters/committed prefix 必须与 abort 前最后一个已验证 snapshot exact 相等，absent
只能是 generation 0 的 empty/reset tuple，且 reason 仅接受该 abort 端点真实可产生并证明无对应 session 的
`coordinator_closed/nonce_reused/replay_ledger_full/run_id_reused/session_not_found`。`t0_pending/session_busy/
generation_exhausted` 即使属于全协议 absent reason，也不能证明 cleanup 完成。任何畸形 terminal 都不得把 cleanup
标为 completed。

## 成功 sidecar

成功 sidecar 必须符合 `tablet-layout-c1b-sidecar/v1`，绑定：

- fixed SHA、producer/APK、observation、validation 与 upstream T0 hash；
- 41-file repository-input catalog 与完整 build-environment binding；
- isolated Android SDK platform-tools trust root、private ADB port/socket、listener owner/server-status/job/
  cleanup/rebind proof、ADB executable/version-output 前后 hash 与 parsed identity；
- runner/C1b lib/C1a 低层 helper/T0 runner 与 sidecar、validator/observation/sidecar schema 的实现 hash；
- Android C1b Model/Probe/Source、debug Provider/Protocol/Coordinator/Controller/Context/Pending Registry、共享
  TabletLayoutProbe/Model、专用 probe service/manifest/resources 与 Gradle/wrapper/verification metadata 的实现 hash；
- Debug/Release APK、artifact proof、两份 merged manifest、packaged manifest/a11y AXML、DEX entries/catalog、
  dependency catalog 与受信 aapt2 binding；
- fresh install 与 local/pre/post APK 一致性；
- provider build challenge hash、canonical endpoint-set hash、control transcript hash 与 generation/counter/timestamp；
- 唯一设备 serial/fingerprint/boot-id 前后 hash；
- upstream T0 original relative path/hash/bytes/CRLF 与唯一一次 exec-in；
- observation/validation/upstream T0 的受控 relative path 与重算 hash；
- `capture_scope=pure_a11y`；
- 恰好两次 a11y frame capture、零 recapture；
- screenshot/OCR/action/gesture/input/settings/target-start/MCP/dispatch 全部零次；
- schema/origin/read-only attestation；
- cleanup 为 `not_required` 或已完成。

observation validator 自身始终输出 `runtime_origin_verified=false` 与 `runtime_evidence=false`；它只能报告
`runtime_binding_inputs_match`。runner 在重新计算全部互相独立的 git/implementation/build/provider/device/APK/T0/
artifact/control 锚点后，才可在 success sidecar 中输出最终 origin/evidence true。ownership/root projection/
topology/IME 的 verified 必须与对应 observed exact 相等，不能单独抬高。layout 与危险能力仍按 observation C1b v1
固定为 false/unsupported。

success sidecar bytes 先通过 closed schema 与跨字段等价校验并只留在内存；private ADB server、
artifact/aapt2/build-environment guards 与全局 device lease 全部 cleanup 成功后才可原子发布。发布后必须从
final 受控 ordinary path 重新读取 exact bytes，执行 strict JSON、schema、跨绑定、secret absence、
implementation snapshot 与所有 artifact hash 复核。
任一 cleanup 失败都禁止发布；任何写后漂移会删除未通过验证的 success sidecar。

## 失败与归因

private ADB server、安装、provider、capture、读取、schema、hash、freshness 或 sidecar 任一失败即冻结该 run；failure evidence 只保存
闭合 reason code 与 false/unsupported 结论，不泄漏 serial/nonce/build challenge/raw UI。不得自动重试，不得在 abort
后继续 status/result/采集，也不得用 fixture 或 C1a evidence 补造成功。旧 `tablet-layout-observation/v2` evidence
永不按 C1b schema 重算。
