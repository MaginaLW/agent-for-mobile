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
2. C1b observation gate、full offline gate（host coverage 29/29）、七场景 host E2E、针对当前 42-input fixed SHA 的
   real isolated host build smoke 与旧 v2/C1a 回归全部通过；
3. build-env、artifact proof、ADB、aapt2、readonly 专项 gate 与凭据扫描全部通过；
4. 独立审查无 P0/P1；
5. 用户针对该 C1b SHA 明确授权一次真机 build/install/只读采集。C1a 授权不能复用。

当前 42-input 离线修复候选已经完成的验证为：build-env 27/27、artifact 32/32、ADB provenance 6/6、private ADB
22/22、T0 sidecar 7/7、aapt2 15/15、readonly 74/74、attempt-failure schema/cross-binding 51/51；observation 公共门仍为
49/49、coverage 89/89。七场景 synthetic host E2E 已通过：fake ADB total 222 = valid 214 + rejected 8；valid
为 private server start/status/kill 8/7/4 + device calls 195，T0 calls 4 是 device 子集，另观测 server exit 7。
runner process 9、fake Gradle 8、fake signer 12、repository inputs 42，synthetic E2E 内 real ADB/JDK/Gradle
executions 全为 0。direct client Job active limit 1、T0 四层 Job 链 limit 4；
official-style auto-start attempts 2，escaped child/listener/side-effect 0，正常 cleanup 无残留。另行 real isolated
host build smoke 的旧 41-input SHA 历史基线曾完整退出 0：受控 JDK/GradleMain 1 次、held-Java ApkSignerTool 1 次、
real ADB 0、inputs 41；该历史 smoke 不构成当前 42-input fixed-SHA 的 smoke，更不构成 C1b build/install/runner、
真实 APK 安装或平板采集。`77473af5223d76b00bf4dbbf33cf44090fde635c` 因 helper 漏载 validator 失败；
`8882add6116ebd3cca547d865f9d142bbbcac1a4` 已令 helper/build core 通过，但 launcher strict verifier 失败。
所以 A 道固定条件第 2 项仍不满足，不能以 core summary、旧 smoke、离线 gate 或已生成过临时 APK 替代。

## 2026-08-29 `8882add` real build-only smoke 结果

`8882add6116ebd3cca547d865f9d142bbbcac1a4` 的唯一 one-shot 已消费，结果为
**helper-pass / launcher-verifier-fail（整体未闭合）**。helper summary 为 `status=passed`、`failure_count=0`：
GradleMain `1`、ApkSignerTool `1`、held aapt2 `4`、held Git `32`，repository inputs `42`；artifact、依赖、
packaged AXML、post-lock seal 与 pre/post provenance 均通过。direct/observed/real ADB、设备枚举、安装、T0、
采集均为 `0`；三项 cleanup 全部 `completed`，workspace/journal/module/local.properties/Java residue 全部为 `0/false`。

外层 launcher 使用固定 PowerShell `7.6.4` 的默认 `ConvertFrom-Json` 读取合法 summary；三个 quoted ISO
时间值被自动提升成 `System.DateTime`，而 verifier 随后要求它们仍为 nonempty `string`，首先在
`started_at_utc` fail-closed。launcher exit `1`，helper start `1`、exit `0`、automatic retry `0`。该失败是
evidence consumer 的确定性类型检查假阴性，不是 build/helper 失败；但 helper passed 只是必要条件，outer
launcher/verifier 未接受时整体仍必须判失败。详细记录见
[`2026-08-29-T-L1-C1b-8882add-real-build-smoke失败.md`](../runs/2026-08-29-T-L1-C1b-8882add-real-build-smoke失败.md)。

后续所有 strict JSON summary reader 必须显式使用 `ConvertFrom-Json -DateKind String` 或等价的 lexical-type
保形解析；quoted ISO timestamp 解析后仍必须是 `[string]`，不得修改 schema/verifier 去接受 `DateTime`。
回归必须由**实际 launcher verifier**消费正对照 summary，不能只测 helper 内部 canary。修复、全门与独审后
固定新 clean SHA，再取得新的 build-only smoke 授权；本轮不得追溯改判，也不得用于设备授权。

## 2026-08-29 `77473af` 42-input real build smoke 结果

`77473af5223d76b00bf4dbbf33cf44090fde635c` 的 one-shot build-only smoke 已消费。受控 GradleMain 执行
`1` 次并到达 artifact proof reader；一次性 helper 漏载 observation validator，closed-JSON walker 不存在，
因此 proof reader fail-closed。ApkSignerTool、held AAPT2、real ADB、设备发现、安装、T0 与采集均为 `0`；
helper start `1`、automatic retry `0`，退出后进程、listener、受控 build workspace 与 journal 无残留；用于审计的
exact one-shot staging scripts 刻意保留，不属于 build residue。

后续 helper 必须把 `tablet-layout-observation-c1b-v1-validator.ps1` 作为 held/pinned input，按
`C1a -> validator -> C1b` 加载，并在 Gradle 前断言两个 strict-JSON walker 均存在；该要求已在
`8882add...` one-shot 满足并由 helper core 通过，不得因后续 launcher 问题而回写为未完成。本轮临时 APK/proof 不得用于安装。
详细证据与边界见
[`2026-08-29-T-L1-C1b-42-input-real-build-smoke失败.md`](../runs/2026-08-29-T-L1-C1b-42-input-real-build-smoke失败.md)。

## 2026-08-28 唯一授权结果

fixed SHA `87ac7b45e79bf658ca6e56b697a24f52fdf7381b` 的一次授权已消费。runner exit 1，失败原因为
private ADB server 未在有界时间内 ready。控制流停在设备发现之前：没有执行 `install -r -t`、T0、
`c1`、`c2` 或 result，也没有 run_id、evidence 目录或 success/failure sidecar。build/seal/artifact
checks 位于失败 guard 之前，只能推断已返回；cleanup 未保留 APK，不能将该推断升级成持久 artifact 证据。
Windows Application/WER 同期记录同轮 isolated ADB 在 15 秒内以六个不同 PID 同签名崩溃；该轮原始材料没有
argv/dump/逐 attempt stderr，因此单凭历史证据不能区分 `server nodaemon` 与 `server-status` client 崩溃。后续只读
源码与实现核对定位到旧 runner 用 numeric `-L tcp:127.0.0.1:<port>` 启动 server，而该 listen 形态不被此 ADB 的
local-listen 判定接受，server 的 retry/fatal 路径与同签名快速退出一致。当前候选改为只对 server argv 使用
`-L tcp:localhost:<port>`，并新增有界、无原始输出的逐 attempt 诊断；这是后续离线归因与修复，不是对旧 run
补造的新 evidence。
退出后的进程、listener、build/temp、ACL journal 与 device lease 残留均为 0。不得自动重试该 SHA，
也不得复用旧 C1a 授权；详细冻结记录见
[`2026-08-28-T-L1-C1b私有ADB启动失败.md`](../runs/2026-08-28-T-L1-C1b私有ADB启动失败.md)。

## 受控构建与宿主边界

执行前必须显式提供 Oracle JDK 21.0.5、Gradle 8.9 与 source Android SDK，并确保 Windows Program Files
KnownFolder 下已安装 canonical Git。runner 将 fixed
HEAD 的 42 个 implementation/build-input 文件（含 private ADB server module 与 attempt-failure schema）按 ordinal
`relative/path=sha256:<lowerhex>` 编目，并把 `file_count=42` 与本 HEAD 重算的 `catalog_sha256` 写入 sidecar；
不得复用 fixture 中的 catalog hash。

build-environment guard 冻结 JDK/Gradle 完整树、Windows Program Files KnownFolder 下的完整 `Git` 安装树，
以及 source SDK 的 `build-tools/35.0.0`、`platforms/android-35`、`platform-tools` 三棵 package tree；随后在 fresh workspace
只复制这三棵树形成 isolated SDK，child 的 `ANDROID_SDK_ROOT/ANDROID_HOME` 只能指向 isolated root。
Git tree binding 固定 9,576 paths、9,489 file identities、85 个内部 hardlink groups 与 6 个关键文件 hash；
不能只冻结入口 executable。
Gradle user home、`user.home`、project/Kotlin cache、process temp 与专用 module build output 都必须 fresh；
受控 build child environment 把 `ANDROID_USER_HOME` 指向 fresh `user.home/.android`。runner 在 Gradle 前
预创建空 `debug.keystore.lock`；只有 Gradle 阶段允许既有 identity 受控可写，返回后紧邻执行唯一 seal；pre/post binding
只允许 `post_gradle_lock_sealed_achieved` 从 false 迁移为 true。canonical token topology、TrustGuard/creation-time
anchor 引用身份和 pre-seal binding 共同阻止移动 seal、shadow/rebind 与等值 guard 替换。
wrapper 不执行，由 held Java 直接启动 `GradleMain` 与 `ApkSignerTool`。构建允许联网，命令不得带
`--offline`，但必须保留 `--dependency-verification=strict`、fresh caches、no build/configuration cache、
rerun 与 no-daemon 约束。证据 catalog 继续拒绝未转义 `=`；只有 cleanup inventory 可接受 Gradle zip-cache 的
合法 `=` 文件名，以便安全盘点并删除 fresh module output。

Git 调用必须使用 exact 15-key environment 并传 `ClearEnvironment`，同时禁用 system/global config、限制
`PATH`；Gradle/apksigner、ADB、aapt2 与 T0 使用各自显式受控 child environment 并传 `ClearEnvironment`。
全局设备 lease 的路径只从 Windows KnownFolder API 取得，不读取或信任 `LOCALAPPDATA`；T0 sidecar 以
runner 发出的 lease token 加入同一把锁，不能另开第二把设备锁。

runner 必须在 `49152..65535` 中随机选择 loopback port，以受控 isolated SDK ADB 的唯一 argv
`-L tcp:localhost:<private-port> server nodaemon` 启动 private server；server listen host 不得换成 numeric
`127.0.0.1`。全部设备命令均显式携带 `-H 127.0.0.1 -P <private-port>`，child environment 同时固定
`ADB_SERVER_SOCKET=tcp:127.0.0.1:<private-port>`，listener proof 也只接受 numeric `127.0.0.1`。
`server-status` 37.0.1 只接受 USB enum `UNKNOWN_USB|NATIVE|LIBUSB|USB_DISABLED|LIBADBUSB`、mDNS enum
`UNKNOWN_MDNS|BONJOUR|OPENSCREEN|LIBADBMDNS|MDNS_DISABLED` 与可选 string `keystore_path`、
`known_hosts_path`；`UNKNOWN_USB` 或 `USB_DISABLED` 不得进入 ready。启动后必须证明 listener owner PID、
`server-status` 所报 executable、Windows job membership 和预期 server process exact 相等；禁止连接、启动或回退到 default 5037。
cleanup 必须关闭 job/server、证明 listener 消失，并成功重新 bind 同一 port 后才算完成。

该 guard 证明的是建立 guard 后的 filesystem-and-environment integrity；它不证明同用户进程内存注入、
预存可写 handle/mapping、ACL/ownership takeover，或同用户并发篡改 intentionally writable fresh build state。

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
- `tablet-c1b-read-only-artifact-proof-v1.json`
- `tablet-c1b-probe-debug.apk`
- `tablet-c1b-probe-release-unsigned.apk`
- `tablet-c1b-probe-debug-merged-AndroidManifest.xml`
- `tablet-c1b-probe-release-merged-AndroidManifest.xml`
- `tablet-layout-c1b-sidecar-v1.json`

run 根目录还保留 fresh T0 原件 `tablet-profile.json`。sidecar 必须独立绑定 fixed SHA、42-file catalog、
build environment、provider build challenge、Debug APK 与 signer、Release unsigned APK、artifact proof、merged/packaged
manifest、DEX entries/catalog、aapt2 binding、private ADB port/socket/server executable、listener owner/job/
cleanup/rebind proof、唯一设备/fingerprint/boot、T0 原始 bytes、c1/c2
generation/counters/timing、control transcript，以及全部 evidence 的受控相对路径与重算 hash。
observation validator 本身永远不能自证 runtime origin；只有 sidecar 全部闭环后，consumer 才能把
`runtime_origin_verified/runtime_evidence` 置真。

success sidecar bytes 只能先暂存；private ADB server、所有 artifact/aapt2/build-environment guard 与全局
device lease 全部成功 cleanup 后，runner 才可原子发布 sidecar，再从 final ordinary path 做 strict JSON/schema/
cross-binding、secret absence 与 artifact hash 读回。任一 cleanup 或读回失败都不得留下 success sidecar。

## 失败与冻结

受控 build、private ADB server、安装、T0、provider、capture、时序、schema、hash、设备/APK 漂移或 cleanup 任一失败，都只原子保留
`tablet-layout-c1b-failure.json` 与已经产生的只读证据；不发布 success sidecar，不自动重试，不借 fixture、
C1a 或 v2 evidence 补造成功。尚未消费 result 的 session 只允许一次 abort cleanup；abort 不是重拍。
abort 返回还必须与发起前最后一个已验证 generation/counters/committed prefix 及闭合 terminal tuple 一致；畸形返回只能
记 `cleanup=failed`，不能因出现 terminal 状态字符串就记为完成。尤其 `ABSENT/t0_pending`、`ABSENT/session_busy`
或 `ABSENT/generation_exhausted` 不属于 abort cleanup 成功终态。

private ADB 若在 run promotion 前失败，不创建普通 run 目录；全部 cleanup 完成后，runner 只原子发布一个
root-level `docs/runs/evidence/tablet-layout-c1b-attempt-<attempt_id>.json`，其 schema 为
`tablet-layout-c1b-attempt-failure/v1`。该记录必须是 `run_id=null`，并令 `pre_device_operations` 中
`build_completed/artifact_checks_completed=true`、`private_adb_guard_created=false`，device discovery、install、
T0、c1、c2、result、capture、abort 计数全部为 0，`runner_invocation_count=1`、
`automatic_runner_retry_count=0`。它不得包含 raw
stdout/stderr、PID、port、socket、argv、path 或 serial，只保存有界 byte counts、captured bytes SHA-256、闭合分类与
cleanup 状态；既有 attempt id 不得覆盖。该记录不是 success/failure sidecar，不授权自动重试；旧 C1a 授权和
2026-08-28 已消费的 C1b 授权都不可复用。

## 结果解释

- `complete + childCount=0 + visited=1 + positive-visible=0` 表示完整观察到 opaque root，不是树可用；
- `window_only` 表示只有 window focus，不是 editor 或目标会话；
- native window title 的 fixed-hash match 不是 toolbar/title-node 或 target proof；
- pure-a11y 仍 opaque 时，下一步另审 window/pane-bound 视觉合同，不能关闭应用多窗或回退整屏坐标猜测。
