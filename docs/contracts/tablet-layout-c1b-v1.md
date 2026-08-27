# Tablet T-L1 C1b v1：受控只读运行合同

## 边界

C1b v1 只运行 `tablet-layout-observation/c1b-v1` 的 pure-a11y producer。它不调用 ToolRegistry/MCP，
不执行 action/gesture/input，不改 settings，不启动目标 App，不截图、不 OCR、不写 raw UI 内容。

运行前必须完成 A 道离线门、release absence 与独立审查，随后固定完整、clean 的 `HEAD`。C 道需要用户针对该
SHA 的新授权；C1a 的授权不可复用。runner 只接受绝对 ordinary `adb` 路径和显式 `-Provision`，恰好执行一次
fresh clean build、一次 `install -r -t`，不卸载也不自动重试。runner 恰好请求 `c1`、`c2` 两帧，宿主间隔
至少 900ms，总 capture span 不超过 15 秒，不补拍。

A 道公共入口 `scripts/run-tablet-layout-observation-c1b-v1-offline-gate.ps1` 必须将本次 fresh gate run id、
exact case/coverage、Kotlin direct-focus 跨层 requirement 与永久 false/unsupported 安全结论原子写入固定
`.checks/tablet-tl1-c1b-v1-offline-gate.summary.json`；consumer 只接受本次 run id 且两分钟内完成的摘要。

宿主 runner 的独立 fake-ADB 门是 `scripts/run-tablet-layout-c1b-offline-gate.ps1`，固定输出
`.checks/tablet-tl1-c1b-host-v1-offline-gate.summary.json`。其 summary 是 closed、单行 strict JSON，绑定 fresh
gate run id、两分钟 freshness/span、26 个 exact coverage、`fake_adb=true`、`real_adb_call_count=0`，并固定所有
runtime/layout/action 结论为 false/unsupported；不能把旧摘要、删减 coverage 或自报成功当作门通过。

## 宿主—provider 协议

传输信任根固定为同一个 ordinary、非 reparse 的 `ANDROID_SDK_ROOT=ANDROID_HOME`，`-AdbPath` 必须 exact 指向其
`platform-tools/adb.exe`；任意 SDK 外 executable 即使可模拟 ADB 也必须在 build/install 前拒绝。runner 在采集前后及
success sidecar 发布读回时校验 `adb version` identity、Installed-as canonical path、executable hash 与 exact version-output
hash，并把这些闭合字段写入 sidecar。authority 固定为 `dev.magina.gateway.tablet.c1b`，端点仅允许 `t0/status/capture/c1/capture/c2/result/abort` 的
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
- canonical Android SDK platform-tools trust root、ADB executable/version-output 前后 hash 与 parsed identity；
- runner/C1b lib/C1a 低层 helper/T0 runner 与 sidecar、validator/observation/sidecar schema 的实现 hash；
- Android C1b Model/Probe/Source、debug Provider/Protocol/Coordinator/Controller/Context/Pending Registry、debug
  manifest 与 gateway Gradle build logic 的实现 hash；
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

success sidecar 先通过 closed schema 与跨字段等价校验，再原子发布；发布后必须从 final 受控 ordinary path 重新读取
exact bytes，执行 strict JSON、schema、跨绑定、secret absence、implementation snapshot 与所有 artifact hash 复核。
任何写后漂移会删除未通过验证的 success sidecar。

## 失败与归因

安装、provider、capture、读取、schema、hash、freshness 或 sidecar 任一失败即冻结该 run；failure evidence 只保存
闭合 reason code 与 false/unsupported 结论，不泄漏 serial/nonce/build challenge/raw UI。不得自动重试，不得在 abort
后继续 status/result/采集，也不得用 fixture 或 C1a evidence 补造成功。旧 `tablet-layout-observation/v2` evidence
永不按 C1b schema 重算。
