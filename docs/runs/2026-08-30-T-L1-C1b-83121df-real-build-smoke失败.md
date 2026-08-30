# T-L1 C1b `83121df` real build-only smoke 失败

## 结论

- fixed SHA：`83121df4c0b00a142fd71d7bc09bb4d9263b9b97`
- 唯一 launcher 窗口：`2026-08-30T01:13:10.0446524Z` → `2026-08-30T01:13:14.6332801Z`
- 整体结论：**失败并冻结，不自动重试。** exact launcher start `1`、exit `1`、automatic retry `0`。
- 停止位置：helper start `0`、verifier load `0`、build start `0`；三个正式输出均不存在。
- 授权边界：本轮只授权 build-only smoke，未授权 install、ADB、设备发现或真机访问；这些操作实际也都是 `0`。

## 授权前绑定

授权前只读 preflight r4 为 `all_checks_passed=true`、`failure_count=0`、static checks `4226`，并绑定：

| 对象 | SHA-256 |
|---|---|
| preflight r4 | `8a38cca0d4d4a094d2d33c41e47b6a60f646cba4b50651c826346c321f661032` |
| preflight r4 receipt | `a05d89f4aa2559c55e3c66398641c991d73b7c744dbddc1e9af8d39d28db8205` |
| launcher | `7996b1fb6118b063e6e949a82f68a2e8711481b2519629f5bdcc9b8cff6c2e79` |
| helper | `f718188ec8a28c35c7dd5f97d2e582c721cf8deb71f8cc2ed9fdd5791dba35d4` |
| verifier | `daf9703c53177e5a3f592ac38a71ccb1271dd6c802220f01c12edb59143766fa` |
| PowerShell 7.6.4 | `db6dd81183fe57d22e03b911ec9a30a2fd7c40542e97743615355a6fb44f458f` |

launcher 通过固定 PowerShell 7.6.4、`-NoProfile -NonInteractive`、仓库 working directory 与 UAC RunAs 启动一次；
没有第二次 `Start-Process`，也没有自动或人工重跑原 launcher。

## 确定根因

launcher 第一次调用 `Add-LauncherHeldDirectoryChain` 时，`$directoryOrder` 是刚创建的空
`List[object]`。函数却把 `$Order` 声明成 `[Parameter(Mandatory)]`，没有
`[AllowEmptyCollection()]`。原 smoke 没有持久化该 ErrorRecord；随后只读 guard probe r1 在相同调用点、相同参数形态下
精确复现为：

```text
FullyQualifiedErrorId:
ParameterArgumentValidationErrorEmptyCollectionNotAllowed,Add-DiagnosticHeldDirectoryChain

Cannot bind argument to parameter 'Order' because it is an empty collection.
```

该复现与原 launcher 的首次调用代码、退出位置和所有副作用事实一致：helper/build 未启动，held directory count 仍为 `0`，且
`$outputTargetsAbsent` 尚未置真，所以 `.log` 与 `.launcher.json` 的正式发布门都没有开放。

PowerShellCore 同期的 `System error.` 不是内部根因。launcher 是 advanced script，最终 `exit 1` 会触发
[PowerShell 已知的 `ExitException/SystemException` 误导性日志](https://github.com/PowerShell/PowerShell/issues/26625)；
真实 `$failure.Message` 只写到 hidden stderr，现场没有保留下来。
因此后续修复还必须建立独立的 failure-only sidecar，不能再把 hidden stderr 当作唯一早期诊断面。

## 非 smoke 诊断与修复验证

诊断均使用新的 staging-only leaf；诊断阶段对原 launcher 的新增 invocation `0`，helper/verifier/build/ADB `0`，
不构成 smoke 重试。

1. elevated Add-Type/context probe：script `d86f5171b297b94fbfee5643bdc9707158140457136a7e0058642dbf22de6141`，
   receipt `ec51c31c14726c7009f2da0089c9f3cc0043b2aea2893ea819ff6b129e8440dc`。它确认管理员 token、
   PowerShell cwd、OS cwd、固定 pwsh 7.6.4 与原 C# type load 全部正确。
2. guard probe r1：script `bbc186668cd125d45e11a3ad2a3a03335f85147dc25d9b365779a18a359eccdd`，
   receipt `92efe78e4741c450f9c6b3a7940df2bfbd0af2b93aa4a8280135eea69481c86e`。它在
   `repo_directory_chain` 精确复现上述 parameter-binding failure，cleanup failure `0`。
3. guard probe r2 只增加新的 receipt leaf 与 `[AllowEmptyCollection()]`：script
   `0daa2270b9357a2fc688a78b2948781b49fae998997c65bec3d0005e81550237`，receipt
   `ee9d9ec783dfa7a588cdb67532f4aaee425b6e079808d2d92b13ada12c1e2545`。它 exit `0`，依次通过
   repo/output directory chains、launcher/helper/verifier/pwsh held files、runtime pwsh reopen、4 个文件与全部目录重验、
   三输出缺席，并在 verifier load 前主动停止；failure/cleanup/recording count 均为 `0`。

r2 仍只比较目录 stable ID，并保留 no-reparse、最终路径与 held-handle；没有恢复目录时间戳等值要求。
文件 stable ID、大小、SHA-256 与时间戳门禁保持不变。所有 probe/preflight receipt 只证明对应持久化字节的完整性；
pass authority 必须来自对应 closed terminal/result 与进程 exit `0` 的联合闭包，receipt 不能单独判绿。

## 退出后副作用审计

- 三个 `83121df` 正式输出及对应原子临时前缀均不存在；本轮启动后 `.checks` 无新建或触碰项；
- helper/launcher、Java/Gradle、ADB 进程均为 `0`，TCP/5037 listener 为 `0`；
- fresh build workspace、ACL journal 与 probe 临时项均为 `0`；module `.gradle` 与 `local.properties` 不存在；
- 既有 `app/tablet-c1b-probe/build` 最新写入早于本轮约五小时，本轮后新建/修改后代为 `0`；
- 运行退出后、开始写本冻结记录前，HEAD/ref 仍为 fixed SHA，index SHA-256 仍为
  `d50a18d5aa7ea7c0ac7ce97b809a685182fb61dd330f11ecec1ce71de7f67649`，工作树快照 clean；随后只有本轮冻结文档进入改动集。

## 后续边界

`83121df` 的一次授权已经消费，不得因根因已修复而重跑或追溯改判。下一候选必须：

1. 在新 launcher leaf 中精确修复空 collection parameter binding；
2. 固定 repo root，并让 Add-Type/路径派生/早期 guard 的原始 ErrorRecord 可写入 failure-only、不可作为成功证据的 CreateNew sidecar；
3. 完成静态复核，在新 clean SHA 上单跑一次只读 `prepared_not_authorized` preflight；
4. 再由用户针对该新 SHA 另行授权一次 build-only smoke。

在新的 outer evidence closure 通过前，不申请设备授权，不执行 install/ADB/采集，也不复用本轮任何临时材料。
