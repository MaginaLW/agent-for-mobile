# T-L1 C1a · 只读 origin-binding 协议 v1

C1a 只回答“这份 `tablet-layout-observation/v2` 是否来自本轮固定代码、fresh APK、同一台设备、同一份
fresh T0 和固定只读入口”。它不把 observation 提升为 runtime accepted，不验收微信布局，不开放编辑器、P0
或 execution。happy sidecar 也必须保持 `runtime_evidence=false`。

## 固定构建与 clean-port 见证

公开 runner 只有三个输入：存在的绝对 `-AdbPath`、完整小写 40 位 `-ExpectedCommitSha`、显式
`-Provision`。任何设备访问前必须满足 HEAD exact、worktree clean；构建后和证据结束前再次复核。

本分支是 clean port，不声称 baseline 是 HEAD ancestor。runner 要求两个 baseline commit object 存在，并逐项
证明 baseline tree blob、HEAD tree blob 与 working `hash-object` 三者均等于固定 OID：

| baseline | path | blob OID |
|---|---|---|
| `b5769df7baba075fda47aec17f249a5caa124b92` | `AndroidTabletLayoutProbeSource.kt` | `cf5f625650d81e830da8e03b2ee8ebf5ce309b7a` |
| 同上 | `TabletLayoutProbe.kt` | `b7b35d1d0c4c1787f1f254224c8ac13ee1668cf7` |
| 同上 | `TabletLayoutProbeModel.kt` | `283eb71675605444c5f829aea9b1c9fd9bd65db0` |
| 同上 | `TabletLayoutProbeTest.kt` | `70843bb488041c5e21204f973c4dbcac526a126e` |
| `4ca32b131007df58f7752c5ee9b2d049cb1cd54e` | `scripts/lib/tablet-intake.ps1` | `4d33c629b95a13a59bb97bdf1490e1edc74b17b4` |
| 同上 | `scripts/run-tablet-intake.ps1` | `572da0c848eefd038ea666d80d741fb73767eb48` |

Gradle 每轮 `clean + assembleDebug`，经子进程环境接收一次性
`TABLET_C1A_BUILD_CHALLENGE=c1a-<32hex>` 与完整 HEAD；challenge 不进 argv、不冒充 APK hash。runner 复核
本地 APK SHA、installed `base.apk` SHA 相等、`apksigner` 唯一证书摘要、installed package/version，以及
provider 回显的 embedded HEAD/challenge/package/version。installed path 只接受 `/data/app/` 下安全闭合段，
拒绝空段、`.`/`..`、空白和 shell 元字符；宿主在 capture 前和 result 后各一次以
`adb -s <serial> exec-out cat <path>` 流式计算 SHA-256，不落整包、不缓冲整包。两次 installed hash、
path hash、本地 APK hash 与 package/version 必须 exact 一致。安装只有一次，无卸载和失败重试。

## 固定 ContentProvider 管道

- authority：`dev.magina.gateway.tablet.c1a`；
- 所有 URI 使用同一个 `nonce=n-<32hex>`，禁止重复 query、`%` 或 `+` 别名；
- 标题只接受固定 hash
  `sha256:5d3510ec998c991305fcede15b32be9ea1c4061d82ab15a3994a38faa243311c`，runner 不接受标题参数、
  不保存标题明文；
- T0：`/t0/<run_id>`，exact mode `w`，query 另含 `title_hash`、当前 APK
  `producer_commit_sha`、当前 APK `producer_artifact_sha256`；
- 其余均 exact mode `r`：`/status/<run_id>`、`/capture/c1/<run_id>`、
  `/capture/c2/<run_id>`、`/result/<run_id>`、`/abort/<run_id>`。

AOSP `content write` 只把 stdin bytes 写入 provider FD，不返回 ACK。Windows 宿主必须经 `adb exec-in` 的 binary
stdin copy 发送原始 T0；不得使用会把 CRLF 改成 LF 的普通 `adb shell` stdin 路径。runner 要求 write 的 stdout/stderr
为空，随后只读一次 status；provider 在该首次 status 内 bounded wait 最多 3000 ms，等待同 key pipe reader
完成，不要求宿主轮询。pending input 自注册起还有独立 15 秒 guard，超时会关闭读端并进入失败收口；
`abort` 与 claim-start 使用同一把锁，因此 abort ACK 一旦返回，晚到 reader 不得再创建 session。
ADB `shell` read 会把多 argv 无 escape 拼回远端 shell，因此 runner 只在这些只读命令中对已通过 closed
grammar 的 canonical URI 加 POSIX 单引号；引号不属于 URI。`exec-in` 会自行 escape command argv，T0 write
必须传 raw canonical URI，预置单引号反而会成为参数内容。两条路径的 provider 最终都收到含完整 query 的原值。

正常次序固定为：

```text
t0(write) → status(read) → c1(read) → host wait >=900 ms → c2(read) → result(read once)
```

从 c1 开始到 c2 完成不得超过 15 秒，不补拍。result 首次成功读取原始 observation 后消费并清除 session；
active/complete session 另有 120 秒主动 TTL，即使宿主不再请求也必须清除 context/frame/observation；TTL scheduler
不可建立时固定失败为 `session_expiry_unavailable`。失败路径最多调用一次 abort，cleanup 失败则整轮失败。禁止 MCP、forward/reverse、dispatch、GatewayService、
Activity/目标 App 启动、input、settings put/delete、IME 切换、截图、logcat、pm clear 与 uninstall。
成功 sidecar 只可能在 result 已消费后发布，因此 `cleanup_status` 固定为 `not_required`；发生 abort 的轮次只能写
failure evidence，不得用 `cleanup_status=passed` 冒充 happy origin claim。

成功 control 是 single-line strict UTF-8 `tablet-c1a-control/v1`，顶层 exact 10 keys，provider exact 8 keys，
每个 JSON scalar 的 string/Boolean/Int64/null 类型也必须 exact，拒绝 singleton array 或 PowerShell coercion；
commit/artifact/HEAD/challenge/package/version/a11y ready 必须与宿主见证一致。`t0_pending`、unknown key、状态或
字段漂移均直接失败，不轮询、不重试。

## 同设备、T0 与隐私闭环

首次 discovery 与 capture 后 discovery 都必须恰好一台 `device` 且 serial exact 相同；两者之间的每条真实
ADB 查询都带 `-s <serial>`。fingerprint 与 boot ID 在前后分别读取、只落 hash，并要求相等。fresh T0 使用
同一 run ID；runner 将其 BOM-less 原始 bytes 原样写入 provider，并要求 T0 中的 serial/fingerprint hash 与
外层设备绑定 exact。

安装后若 enabled setting 不含固定 full/short component，立即 `needs-user`；已 enabled 时允许最多
45 秒、每秒一次的只读 `dumpsys accessibility` 绑定等待。只在 Bound services 区段接受
full/short component；当 enabled exact 已成立时，也接受 vivo 的 exact `label=执行网关`。错误区段或相似 label 不得冒充。

落 observation、validation、sidecar 前，在内存中扫描 raw serial、fingerprint、boot ID、nonce 与 build
challenge；命中只返回固定 `privacy_leak`，不回显秘密。sidecar 只保存 hash、六 blob OID、runner/validator/
schema hash与静态只读 policy。实现 hash 还闭合 C1a library 与 T0 adb sidecar cmd/script；sidecar
发布前后都重验 HEAD/clean/六 blob/这六个 hash、本地 APK hash，以及已发布 T0/observation/validation
三份文件的冻结 hash；sidecar 另绑定 validation 的相对路径与 artifact hash，任何后验失败都会撤回成功 sidecar。机器 schema 是
[`tablet-layout-c1a-sidecar/v1`](tablet-layout-c1a-sidecar-v1.schema.json)。

## C1a claim scope

happy sidecar 的机械字段固定为：

- `c1a_origin_binding_verified=true`、`c1a_probe_entrypoint_read_only=true`、
  `observation_schema_valid=true`；
- `mcp_used/dispatch_used/screen_capture_used/settings_mutation_used/target_app_started=false`；
- `runtime_evidence/layout_accepted/wechat_layout_verified/editor_action_ready/execution_grant=false`；
- `p0_capability=unsupported`。

只有 A3/C1b 新合同和新独审才能讨论 runtime accepted 或更高结论。
