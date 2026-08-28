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
2. C1b observation gate、full offline gate（host coverage 26/26）、五场景 host E2E、real isolated host build smoke 与旧 v2/C1a 回归全部通过；
3. build-env、artifact proof、ADB、aapt2、readonly 专项 gate 与凭据扫描全部通过；
4. 独立审查无 P0/P1；
5. 用户针对该 C1b SHA 明确授权一次真机 build/install/只读采集。C1a 授权不能复用。

当前 A 道实现与验证已完成：build-env 27/27、artifact 32/32、ADB provenance 6/6、private ADB
16/16、T0 sidecar 7/7、aapt2 15/15、readonly 70/70。五场景 synthetic host E2E 已稳定复跑通过：fake ADB
total 219 = valid 211 + rejected 8；valid 为 private server start/status/kill 6/6/4 + device calls 195，T0
calls 4 是 device 子集，另观测 server exit 6。runner process 7、fake Gradle 6、fake signer 10、repository
inputs 41，synthetic E2E 内 real ADB/JDK/Gradle executions 全为 0。direct client Job active limit 1、T0 四层 Job 链 limit 4；
official-style auto-start attempts 2，escaped child/listener/side-effect 0，正常 cleanup 无残留。另行 real isolated
host build smoke 已完整退出 0：受控 JDK/GradleMain 1 次、held-Java ApkSignerTool 1 次、real ADB 0、inputs 41；
独立复审 P0/P1/P2=0。该 smoke 不构成 fixed-SHA C1b build/install/runner、真实 APK 安装或平板采集。

## 2026-08-28 唯一授权结果

fixed SHA `87ac7b45e79bf658ca6e56b697a24f52fdf7381b` 的一次授权已消费。runner exit 1，失败原因为
private ADB server 未在有界时间内 ready。控制流停在设备发现之前：没有执行 `install -r -t`、T0、
`c1`、`c2` 或 result，也没有 run_id、evidence 目录或 success/failure sidecar。build/seal/artifact
checks 位于失败 guard 之前，只能推断已返回；cleanup 未保留 APK，不能将该推断升级成持久 artifact 证据。
Windows Application/WER 同期记录同轮 isolated ADB 在 15 秒内以六个不同 PID 同签名崩溃；现有材料没有
argv/dump/逐 attempt stderr，尚不能区分 `server nodaemon` 与 `server-status` client 崩溃。
退出后的进程、listener、build/temp、ACL journal 与 device lease 残留均为 0。不得自动重试该 SHA，
也不得复用旧 C1a 授权；详细冻结记录见
[`2026-08-28-T-L1-C1b私有ADB启动失败.md`](../runs/2026-08-28-T-L1-C1b私有ADB启动失败.md)。

## 受控构建与宿主边界

执行前必须显式提供 Oracle JDK 21.0.5、Gradle 8.9 与 source Android SDK，并确保 Windows Program Files
KnownFolder 下已安装 canonical Git。runner 将 fixed
HEAD 的 41 个 implementation/build-input 文件（含 private ADB server module）按 ordinal
`relative/path=sha256:<lowerhex>` 编目，并把 `file_count=41` 与本 HEAD 重算的 `catalog_sha256` 写入 sidecar；
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

runner 必须在 `49152..65535` 中随机选择 loopback port，以受控 isolated SDK ADB 启动 private
`server nodaemon`；全部设备命令均显式携带 `-H 127.0.0.1 -P <private-port>`，child environment 同时固定
`ADB_SERVER_SOCKET=tcp:127.0.0.1:<private-port>`。启动后必须证明 listener owner PID、`server-status` 所报
executable、Windows job membership 和预期 server process exact 相等；禁止连接、启动或回退到 default 5037。
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

run 根目录还保留 fresh T0 原件 `tablet-profile.json`。sidecar 必须独立绑定 fixed SHA、41-file catalog、
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

## 结果解释

- `complete + childCount=0 + visited=1 + positive-visible=0` 表示完整观察到 opaque root，不是树可用；
- `window_only` 表示只有 window focus，不是 editor 或目标会话；
- native window title 的 fixed-hash match 不是 toolbar/title-node 或 target proof；
- pure-a11y 仍 opaque 时，下一步另审 window/pane-bound 视觉合同，不能关闭应用多窗或回退整屏坐标猜测。
