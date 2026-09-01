# Git 恢复 `A-Acquire` r1 单跑失败

## 结论

- 用户授权精确绑定 parent SHA-256
  `e4f2638b5eec7ffbcb0716b12216addbbadfdcc9bf2a0e7c6b2451e3c96e6ed5` 与 leaf SHA-256
  `d7939294d6457848cdcddfe0f61e384caaf8855cf54eb1b3a099e8ae217f3003`，仅允许一次 `A-Acquire`。
- 该授权已消费：caller 只启动一次 parent，parent 只启动一次固定 PowerShell child；parent/child 均已退出，
  automatic retry=`0`，外部实际 exit=`1`。同一 pair 冻结，不追溯改判、不重跑。
- 失败发生在 leaf 正文之前。PowerShell `AuthorizationManager` 在默认 execution policy 下拒绝把 Volume-GUID
  路径作为 `-File` 参数；因此应用层 asset HTTP attempt=`0`，没有下载、observed asset hash、Authenticode
  结果、success/failure receipt 或 installer。
- 专用输出目录退出后仍 exact-empty；installer、Git、INF 应用、build/Gradle、ADB、设备发现、install、T0 与
  C1b 采集均为 `0`。本次 A 失败不放行 `B-Backup`，也不继承或产生 B/C/D/E 授权。

## 唯一运行窗口与外层观察

- 唯一 parent PID：`57856`
- UTC 窗口：`2026-09-01T10:06:56.7941639Z` → `2026-09-01T10:07:00.4826536Z`
- elapsed：`3688 ms`
- parent external exit：`1`
- caller 观察：stdout/stderr terminal 均 closed
- caller stdout：`39 B`，SHA-256
  `97c621c23ae8d627611d796130d812dc16beed1ce7a1f53e8c6cb951c43a9a4b`
- caller stderr：`1297 B`，SHA-256
  `dac5edf81b472d99f78d601448142ad9e744a1a22d1758a553f43facca30c914`

外层采集器随后尝试用其宿主 PowerShell 不支持的 `ConvertFrom-Json -DateKind String` 解析 parent 输出，因而没有
形成结构化的外层解析对象；这发生在目标进程结束和原始 byte/hash 捕获之后，不改变目标运行、退出码或下列 parent
失败 JSON。原始流长度/hash 与 parent stderr JSON 已保留，本次未以解析失败掩盖 A 的首因。

## parent 结构化失败

parent 发布 `git-for-windows-acquire-parent-result/v1` 的 closed failure：

| 字段 | 观察值 |
|---|---|
| terminal / pass eligible | `failed` / `false` |
| phase | `child_nonzero_exit` |
| primary type | `AgentForMobile.ChildExitCode` |
| primary message | `The download leaf exited nonzero: 1` |
| child started / exit | `true` / `1` |
| authoritative / external exit | `1` / `1` |
| timed out | `false` |
| Job active / total / terminated | `0 / 1 / 0` |
| child stdout | `0 B` / SHA-256 `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` / EOF |
| child stderr | `51 B` / SHA-256 `f1f58a622cc8a32328cdf30d18acc1ccd970642522ef745b71db56ea074ea32e` / EOF |
| stdout/stderr overflow | `false / false` |
| success receipt / failure receipt / installer | `absent / absent / absent` |
| runtime watcher events/errors | `0 / 0` |
| failure-target watcher events/errors | `0 / 0` |
| secondary failures | `0` |

r1 只记录 child stderr 的 byte count/hash，没有把 51-byte 文本放入 parent JSON。这不影响 nonzero fail-closed，
但会降低诊断性；下一候选 r2 已让有界、strict-UTF-8、query-redacted 的 preview 作为纯诊断字段公开，并让 renderer
自身失败时仍回退输出原 primary 的 phase/type/message/hresult 与 external exit。

## 根因复核

运行后使用不联网的两行 canary，在同一个固定 PowerShell 7.6.4 与同一种 Volume-GUID `-File` 形态下复核：

1. 默认 policy：exit=`1`，stderr 精确为
   `SecurityError: AuthorizationManager check failed.\r\n`，`51 B`，SHA-256 与 child stderr
   `f1f58a…32e` 完全一致。
2. 增加固定 `-ExecutionPolicy Bypass`：exit=`0`，且 probe 侧观察到的 `$PSCommandPath` 仍是精确 Volume-GUID 路径。

这证明本次 child 在 leaf 建立 stable ID、no-reparse、最终路径与 held-handle 门禁之前，已经被宿主的
`AuthorizationManager` 拒绝；它不是 HTTP、redirect、hash、Authenticode 或 receipt 逻辑失败。canary 已删除，
未执行或点源下载 leaf，也未联网。

`Bypass` 只解决该宿主的脚本启动门：CLI 参数作用于整个 child current session，可能被 PowerShell 后代继承，
可能被更高优先级 machine/user policy 覆盖，且 effective policy 未由 leaf 独立取证。它不持久修改策略，不改变
token/elevation，不是 content/identity authority，也不是网络或进程创建沙箱。parent 虽持有并复核 leaf 的 bytes、
stable ID、ReadOnly、single-link、最终 DOS/Volume-GUID 路径，PowerShell 引擎仍会按命名路径重新打开脚本；
pre-execution read identity 是明确保留的外部 trust boundary。

## 退出后冻结与不变证据

| 对象 | 状态 |
|---|---|
| r1 parent | ReadOnly，124650 B，2660 行，SHA-256 `e4f2638b…e6ed5`，ordinary/non-reparse/single-link |
| r1 leaf | ReadOnly，70543 B，1521 行，SHA-256 `d7939294…f3003`，ordinary/non-reparse/single-link |
| INF r1 | ReadOnly，476 B，SHA-256 `50a17bce…2d80` |
| PowerShell 7.6.4 | 301368 B，SHA-256 `db6dd811…458f` |
| runtime tree | 983 files / 54 dirs / 296034085 B |
| runtime file catalog | `038b2a680cf375d6fdc8b718a7895d64812700d78a737ea3243808f77be1b225` |
| runtime directory catalog | `295b0a0246e83c4a6e8e2f0da7469afe839b7144e9a9d688bb8b0c54c46313df` |
| 专用输出目录 | ordinary/non-reparse、同一稳定对象、exact-empty |

退出后没有目标进程；临时 canary 不存在。没有需要冻结的 output evidence 文件，也没有执行自动清理或重试。

## 下一候选与授权边界

保留 r1 与 frozen leaf 不变，新的 repo-external parent r2 只针对本次启动失败收窄：

- 显式固定 `-ExecutionPolicy Bypass`，并逐项 Ordinal 校验完整 child `ArgumentList`；
- 保留 leaf stable ID、no-reparse、最终 DOS/Volume-GUID 路径、ReadOnly/single-link 与 held-handle 门禁；
- 结果 schema 升为 v2，诚实披露 whole-session policy、descendant inheritance、named-path reopen 与
  pre-execution identity 边界；
- failure stream 增加有界诊断 preview，byte count/SHA/EOF/overflow 仍是流 authority；renderer 失败不会遮蔽原 primary。

r2 已以 132271 B、2791 行、Parser0、ReadOnly、ordinary/non-reparse/single-link 冻结，SHA-256
`04875b31db6b1743a5c6079d62bfe0cc5e727a8f1e8ceaa6b2a10909b061cba9`；完整待办见
[下一候选待完成项](2026-08-30-T-L1-C1b-下一候选待完成项.md)。r2 没有被本次授权覆盖，未执行；只有用户另行同时
绑定 r2 parent 与原 leaf 完整 SHA-256 的新一次性 `A-Acquire` 授权后，才可单跑一次。r2 A 成功也只把下一动作
变为申请 `B-Backup`，不允许直接执行 B/C/D/E。
