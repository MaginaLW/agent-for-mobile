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

1. 在独占普通 clone 中固定完整 40 位候选 commit SHA；工作树 clean，本轮实现与构建输入目录按受控合同重算并绑定；
2. 该 SHA 的 C1b observation gate、项目全量门、七场景 host E2E、real isolated host BuildOnly 与旧 v2/C1a 回归全部通过；保存各门实际退出、覆盖、输入绑定与独立读回，不能沿用旧轮统计值；
3. build-env、artifact proof、ADB、aapt2、readonly 专项 gate 与凭据扫描全部通过；
4. 独立审查无 P0/P1，collector/reader/freezer 覆盖两个设备发现检查点及尚无 run ID 的失败路径，本轮 Ready 的主机条件成立；
5. 用户针对该 C1b SHA 明确授权一次真机 build/install/只读采集。C1a、旧 C1b、BuildOnly 与只读 preflight 的授权均不能复用或扩大。

候选 A1—A5 顺序、R3 证据消费链及当前状态见 [现行 backlog](../backlog.md)；
exact pair/r14 的源码准备见 [候选源码准备](T-L1-c1b-candidate-source.md)。
历史门结果、临时 APK 或旧 Ready 不构成本轮通过或授权。设备执行前还须以本轮证据核对现场就位与唯一设备。

## build-only outer verifier 与只读 preflight

外层 verifier 是 42 个 runner/helper implementation/build input 之外的独立 evidence consumer；它不改变
`repository_inputs.file_count=42`，而由 exact SHA-specific launcher 另行 pin/hold。其完整闭合规则见
[受控运行合同](../contracts/tablet-layout-c1b-v1.md)：summary 必须递归拒绝 duplicate property，保持 closed key set、
canonical Int64 token、exact CLR type 与七位小数 `Z` 结尾的 UTC timestamp string；不得只修日期提升而继续接受
宽松 JSON。

summary 必须来自 launcher 固定 expected parent 下的 ordinary、非 reparse、single-link file。验证从同一个
deny-write/delete held stream 完成 length/hash/strict-UTF-8/parse，并闭合 parent guard、opened identity 与最终路径
identity。launcher 记录 `Process.Start` 紧前/确认 helper 退出紧后的 execution envelope。`status=passed` 仍由公共
verifier 要求三个 timestamp 全部存在、落在 envelope 内，observer end 晚于 start、不晚于 completed，且距
completed 不超过 5 秒；`status=failed` 由独立 closed validator 消费，observer timestamp 可为 `null`，但必须有
非 canary observer reason，存在时仍须满足 envelope 与顺序，5 秒 tail 不作为失败证据的额外门禁。

按 [现行 backlog](../backlog.md) 的 A1—A5 顺序固定并核验本轮候选；以下为
exact pair、只读 preflight 与 BuildOnly 的通用核对项，均须绑定该候选完整 SHA：

1. 完成 outer-verifier 专项回归、全门与无 P0/P1 独审；这些离线结果本身不是 smoke；
2. 形成最终 clean HEAD，再为该完整 SHA 生成 exact repo-external helper 与 launcher；
   可复现的 pair/r14 源码准备入口与独立离线回归见 [候选源码准备](T-L1-c1b-candidate-source.md)；review drafts 不是已发布工件；
3. launcher 固定并持有 self/helper/verifier/pwsh 的 ordinary identity 与 hash；verifier exact dot-source load=`1`，
   captured private strict-parser 与 exact-property `FunctionInfo` 各 invoke=`1`；`status=passed` 时公共 verifier
   `FunctionInfo` invoke=`1`，`status=failed` 时公共 pass verifier invoke=`0`；不得有 inline verifier、fallback 或
   caller-selected verifier path；
4. 首次目录-chain 调用必须保留 Mandatory `$Order` 并显式声明 `[AllowEmptyCollection()]`；preflight 机械核验该精确
   修复及 stable ID/no-reparse/final-path/held-handle 全部仍在；
5. launcher 固定 repo root 并验证 PowerShell provider cwd 与 OS cwd；early failure sidecar 只能 CreateNew、固定 failed-only
   语义，且记录失败本身时的 secondary error 不得覆盖原始 ErrorRecord；
6. helper hard deadline exact 为 45 分钟，不得无界等待；超时后 process-tree kill 与 output drain 各有 30 秒上限，
   任一终止、drain、guard 或 cleanup 失败都 fail closed；helper 仍固定 start `1`、retry `0`；
7. 静态门必须证明 active-process count 是含唯一 native call 的单一 cast RHS；validation 与 cleanup 各自保留不可互相
   覆盖的 Job/child snapshot；合法 failed summary 的 held binding、严格解析和原因提取先于 generic exit/stderr；
8. 对 exact staging 执行只读 preflight；除 clean SHA、hash/identity、load/invoke、deadline、既有输出与 failure-only
   sidecar 缺席、module build output no-follow absent 外，还必须被动确认宿主 `adb.exe` 与 TCP/5037 listener 都为零，
   才可发布 `prepared_not_authorized`；snapshot unavailable 也 fail closed；
9. `prepared_not_authorized` 不执行 launcher/helper/Gradle/JDK/ADB、不访问设备、不自动终止宿主进程，也不是 smoke 或
   授权。冻结后到 one-shot 之间不得运行会重建 module `build` 或重启 default ADB 的工具；授权前须先用不调用
   launcher/Git/构建/ADB 的探针证明 UAC 提升后的进程持有管理员令牌。只有用户针对该完整 SHA 明确授权，才可由
   同样提升的进程运行一次 launcher，automatic retry 固定为 `0`；启动令牌和 mandatory 参数门见
   [候选源码准备](T-L1-c1b-candidate-source.md)。

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
任何已消费的 C1b 授权都不可复用。

## 结果解释

- `complete + childCount=0 + visited=1 + positive-visible=0` 表示完整观察到 opaque root，不是树可用；
- `window_only` 表示只有 window focus，不是 editor 或目标会话；
- native window title 的 fixed-hash match 不是 toolbar/title-node 或 target proof；
- pure-a11y 仍 opaque 时，下一步另审 window/pane-bound 视觉合同，不能关闭应用多窗或回退整屏坐标猜测。

## 历史冻结记录

2026-08-28 至 08-31 的旧候选、离线门快照和已消费授权见
[日期化历史附录](../backlog-archive.md#c1b-dated-history)；过程摘要见
[历史归档 §4](../backlog-archive.md#4-验收批次)。逐轮原件：
[87ac7b](../runs/2026-08-28-T-L1-C1b私有ADB启动失败.md)、
[77473af](../runs/2026-08-29-T-L1-C1b-42-input-real-build-smoke失败.md)、
[8882add](../runs/2026-08-29-T-L1-C1b-8882add-real-build-smoke失败.md)、
[83121df](../runs/2026-08-30-T-L1-C1b-83121df-real-build-smoke失败.md)、
[21d2986](../runs/2026-08-30-T-L1-C1b-21d2986-real-build-smoke失败.md)、
[690693a](../runs/2026-08-31-T-L1-C1b-690693a-real-build-smoke失败.md)。
旧轮结果不能替代新候选的 preflight、BuildOnly、Ready 或设备取证。
