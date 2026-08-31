# T-L1 C1b `690693a` real build-only smoke 失败

## 结论

- fixed SHA：`690693ae4113a91f7590457a888b56e93b6e200b`
- 唯一外层调用窗口：`2026-08-31T14:00:00.8919744Z` → `2026-08-31T14:00:12.5895503Z`
- 整体结论：**失败并冻结，不自动重试。** launcher start `1`、exit `1`；helper start `1`、exit `1`；
  automatic retry `0`。
- helper 的真实首因是宿主在 smoke 前已有 1 个 `adb.exe` 与 1 个 TCP/5037 listener；launcher 随后又因
  nullable string 的 PowerShell 参数绑定缺陷遮蔽了该 primary。
- GradleMain、ApkSigner、aapt2、held Git、设备枚举、install、T0 与采集均为 `0`。
- 授权边界只有 build-only smoke；没有授权 install、ADB 命令、设备发现或真机访问，本轮也没有执行这些操作。

## 授权前 read-only preflight

r11 leaf 只变更独立 receipt 名称，保留 stable ID、no-reparse、最终路径、held-handle、文件身份/哈希/长度/
mtime、clean HEAD 与三类失败真值门禁。它恰运行一次并由外层观察 exit `0`、terminal closed；
primary/cleanup/recording failure 均为 `0`，四次只读 Git 全部闭合，且没有启动 launcher/helper/build/ADB/设备。

| 对象 | SHA-256 |
|---|---|
| preflight r11 leaf | `371b32bec50166c537e299607f927e483ba4d49d7f6a3e91636e6edd528aa1f6` |
| preflight r11 receipt | `be20bd9a3f15eb1708050e0ada53ff8f789dca943751717818ffb86388cea2d0` |
| launcher r9 | `593ef4f4bc0f31d517e03ae779776d86c5810965811f4976ee89219c08ee1600` |
| helper r9 | `7b8b228f2d1a2946d82898cc36c023a42918412ec3ca7075e0bd65623312693c` |
| verifier | `daf9703c53177e5a3f592ac38a71ccb1271dd6c802220f01c12edb59143766fa` |
| PowerShell 7.6.4 | `db6dd81183fe57d22e03b911ec9a30a2fd7c40542e97743615355a6fb44f458f` |

launcher 经固定 PowerShell 7.6.4、`-NoLogo -NoProfile -NonInteractive`、仓库 working directory 与 UAC
RunAs 启动一次；没有第二次 `Start-Process`，也没有自动或人工重跑。

## helper 的真实首因：宿主已有 default ADB

helper 在 build-environment guard 之前被 ADB-zero boundary 拒绝：

```text
primary: C1b build-only smoke requires zero pre-existing adb processes and zero TCP/5037 listeners.
```

边界快照的 pre/post `adb.exe` 进程数均为 `1`，pre/post TCP/5037 listener 数也均为 `1`；进程来自宿主既有
`pcsuite\adb_41\adb.exe`，创建时间早于 smoke 约 20.5 小时。`observed_adb_process_start_count=0` 与
`direct_adb_attempt_count=0` 共同证明它不是本轮启动。helper 的另外两条 reason 分别是计数闭包派生的
`ADB-zero boundary failed...` 与早退派生的 `core: real build smoke result is missing.`，不是另两个 primary。

因此本轮是 **pre-build environment failure**，不是 Gradle、APK、签名、artifact proof 或设备链失败。
summary 记录 GradleMain/ApkSigner/aapt2/held Git 均为 `0`；build environment 未获取，module `build`、`.gradle`、
`local.properties`、fresh workspace 与 recovery journal 均无残留。

## launcher 的二次遮蔽

helper 已原子发布合法 closed failed summary，stdout 也精确等于 summary bytes + CRLF：

- summary：`2654` bytes，SHA-256 `e122ce9f07fc8b460f35fe9dc90819b4a823ca6d13f83a2b5a6aff79b7d8c139`
- summary + CRLF / captured stdout：`2656` bytes，SHA-256
  `6531c757bd498792e3cc88a0e5c51c857a85eed7cb3ff63ad98ae12deeae39a1`

但 `Open-LauncherHeldExactFile` 把可选参数声明为 `[AllowNull()][string]$ExpectedSha256`。调用方打开刚产生的
summary 时传入 `$null`；PowerShell binder 将它转换为空串，代码仍以“非 null”进入 64 位 lowercase hex 校验并必然抛出：

```text
Pinned summary SHA-256 is not canonical lowercase hex.
```

failure-only sidecar 因而记录 `phase=summary_verification`。verifier function 已捕获并加载 `1` 次，但 summary
parse/invoke 都是 `0`；顶层 result 只公开上述 launcher 错误，helper 的合法 primary 再次被遮蔽。该缺陷对 passed/
failed summary 都可达，不是本次 ambient ADB 独有的失败。

下一 leaf 必须在 canonical check 与最终 hash compare 两处都用明确的“有 expected hash”谓词，例如
`-not [string]::IsNullOrEmpty(...)`；null/empty 只能表示“仍做 held-file hashing，但没有预先 SHA pin”，不能绕过
stable ID、no-reparse、最终路径、held handle、长度、mtime 与实际 SHA 计算。

## 持久失败证据

下列本机文件已设为 ReadOnly；它们位于 gitignored `.checks` 或 `${TEMP}`，不入库：

| 文件 | bytes | SHA-256 |
|---|---:|---|
| `.checks/tablet-c1b-real-build-smoke-690693a.summary.json` | 2654 | `e122ce9f07fc8b460f35fe9dc90819b4a823ca6d13f83a2b5a6aff79b7d8c139` |
| `.checks/tablet-c1b-real-build-smoke-690693a.log` | 2231 | `9bb5f7d3a5da6b2496a6fe71cc04c543f6d8b0e7c5f3d1b6900758d4ebb5c94b` |
| `.checks/tablet-c1b-real-build-smoke-690693a.launcher.json` | 5234 | `4534615bcc968b41d846912017bb643313f1a1798d9ce226b8bf67132d5186ad` |
| `${TEMP}/tl1-c1b-next-staging-template/launcher-690693a-r9.failure.json` | 3164 | `d284fa8e0b7c6240ba86429e3df26af1a3b6c1b69ad3f3e16d5985fd201068c5` |

launcher result 为 `status=failed`、`pre_publication_pass_closure=false`；外层实际观察 exit `1`，且进程退出后
failure sidecar 存在，因此不满足“external exit `0` 且 sidecar absent”的最终成功权威。不能以 summary 的结构正确、
stdout 绑定正确或 cleanup 成功追溯改判为 pass。

## 退出后副作用审计

- exact launcher/helper PowerShell、Java、Gradle 与 C1b child 进程均为 `0`；helper 自然退出，Job Object validation/
  cleanup active count 均为 `0`，stdout/stderr drain 完成，未 kill、未超时；
- module `build`、`.gradle`、`local.properties`、fresh Gradle workspace、ACL journal、atomic temp 均不存在；
- launcher process/job/gate、固定文件/目录 guard 与敏感 buffer cleanup 全部 `completed`，cleanup failure `0`；
- 唯一仍存在的 `adb.exe` / TCP/5037 listener 是 smoke 前的手机套件进程，本轮没有终止或修改它。

## 后续边界

`690693a` 的一次授权已经消费，不得因已定位 ambient ADB 或 launcher 缺陷而重跑或追溯改判。下一候选必须：

1. 新建 launcher leaf，修复 optional expected SHA 的 null/empty 判定，并用静态门与固定 PowerShell 正/负对照证明
   summary 无 pin 时仍能 held-bind、实际 hash、核对 stdout、严格解析 failed summary；
2. read-only preflight 增加被动宿主快照：`adb.exe` 与 TCP/5037 listener 必须都为 `0`。该检查不得运行 adb、
   不得枚举设备，也不得自动终止未知进程；
3. 用户关闭对应手机套件，或另行明确授权精确的宿主进程处置后，先确认 ADB/listener 为零；
4. 更新本册、backlog 与 STATUS 后固定新的完整 clean HEAD、raw index 与 repo-external helper/launcher/preflight，完成
   独立静态复核，再只运行一次 read-only preflight；
5. 只有该 preflight 闭合后，才可针对新的完整 SHA 另行申请一次 build-only smoke。install、设备发现、C1b 采集及
   navigation/conversation/target/regions/layout/微信/editor/action/P0/execution 仍未放行。
