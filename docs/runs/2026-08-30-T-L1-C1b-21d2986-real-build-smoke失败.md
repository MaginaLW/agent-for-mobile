# T-L1 C1b `21d2986` real build-only smoke 失败

## 结论

- fixed SHA：`21d29866a428f49e6ea79fe7fedc56f6cf42e16e`
- 唯一外层调用窗口：`2026-08-30T09:42:11.2126975Z` → `2026-08-30T09:42:26.6992111Z`
- 整体结论：**失败并冻结，不自动重试。** launcher start `1`、exit `1`；helper start `1`、exit `1`；automatic retry `0`。
- 停止位置：helper 在 build-environment guard 中、直接 GradleMain 调用之前 fail-closed。GradleMain、ApkSigner、
  aapt2、held Git、verifier invoke、ADB、设备发现、install、T0 与采集均为 `0`。
- 授权边界：本轮只授权 build-only smoke；没有授权 install、ADB、设备发现或真机访问，这些操作实际也都是 `0`。

## 授权前 read-only preflight

历史 r2 与 r6 原样保留。恢复 exact clean `21d2986` 时，旧 raw index 的 stat-cache 仍对应 CRLF 文件大小；六份
文档的 LF raw/filtered blob 已逐项等于 HEAD，但 Git `ls-files --modified` 仍按陈旧 stat 报 modified。先在 alternate
index 证明对精确六路径执行普通 `git add -- <paths>` 只刷新 stat，不改变 stage/tree/flags；再应用到真实 index，最终
raw index SHA-256 为 `d77a4c32cfa322bae1b33ba4026d9f63cc7e02f4bbab17b019f55c6f8cc44213`，cached diff 与
renderer-view modified/others 均为 `0`。

新的 r7 只把 r6 的 receipt leaf 与 raw index pin 重绑；其余 AST、stable ID、no-reparse、final path、held-handle、
文件 identity/hash/size/mtime 与 failure truth 门禁逐字节继承。独立静态复核为 P0/P1/P2=`0/0/0`：

| 对象 | SHA-256 |
|---|---|
| preflight r7 leaf | `2f9fba1598e5b912787f4e9f4b7699b7cf64243f3a273f2eacbf999aee7c6c31` |
| preflight r7 receipt | `1cea8a95f608a6ed5c4150d8b09755d3999712f568dceb368bea74c88c80800d` |
| launcher | `a98740b08b0eae484569b53c2cd474dfcb1d5c454680bd3b86d77fdcbd313bcb` |
| helper | `00609062d90207190880510698d8f2d6e138768031782fcd248c1ac03fda117f` |
| verifier | `daf9703c53177e5a3f592ac38a71ccb1271dd6c802220f01c12edb59143766fa` |
| PowerShell 7.6.4 | `db6dd81183fe57d22e03b911ec9a30a2fd7c40542e97743615355a6fb44f458f` |

r7 read-only preflight 恰运行一次：外部 exit `0`、stderr empty、terminal `closed`、receipt published，
primary/cleanup/recording failure count 均为 `0`。公开 `overall_passed=false` 是进程尚未被外层观察 exit 时的保守字段；
与外部 exit `0` 联合后才形成 `prepared_not_authorized`。preflight 没有执行 launcher/helper/Gradle/ADB 或设备操作。

## 真正首要失败：既有 module build output

helper 在建立 build-environment guard 时发现 `app/tablet-c1b-probe/build` 已存在。合同要求该路径在 guard 前严格
absent，且拒绝清理未知既有内容，因此立即抛出：

```text
C1b module build output 必须在 guard 前 absent；拒绝清理未知内容。
```

failed summary 同时记录 `module_build_residual=true`、`real_jdk_gradlemain_execution_count=0`、
`build_environment_cleanup=not_acquired`。该目录含 1,317 个文件、688 个子目录、28,842,887 bytes；最新后代 mtime
为 `2026-08-29T20:12:13.5800147Z`，早于本轮约 13.5 小时。其内容与 `c4e42667` 普通全量 Gradle 门的
`BUILD SUCCESSFUL` 记录、内嵌 commit 与 task 集合一致；它不是本次 smoke，也不是此前 three-output smoke 的新产物。

因此本轮是 **pre-Gradle environment guard failure**，不是 Gradle、APK、签名、artifact proof 或设备链失败。
summary 的另两条 `core result is missing` 与 residue 原因是首要失败的派生结果。

## launcher 诊断遮蔽

failure-only sidecar 正确保留了失败 phase 与 exception chain，但它记录的是泛化的 closure failure，而不是上述 helper
primary。原因有两层：

1. frozen launcher/template 把 active-process count 写成跨行表达式：

   ```powershell
   $helperJobActiveProcessCount = [long]
       [TL1C1bNextLauncherNativeV1]::GetActiveProcessCount($helperJob)
   ```

   PowerShell AST 将其解析为“给变量赋 `System.Int64` 类型对象”与“独立调用”两个语句，validation-time
   `helperChildTerminationVerified` 因而为 false。finally 随后重查到 active count `0`，所以最终 launcher result 又显示
   root exit、job zero、child termination 与 drain 全部为 true；这是 cleanup 后状态，不追溯修正先前误报。
2. 即使修正该 cast，launcher 仍在 held-bind/验证 failed summary 之前先因 helper exit `1` 或 stderr nonempty 抛泛化错误，
   会继续遮蔽 helper 的具体 primary。

该缺陷没有造成 false-pass：launcher 仍 exit `1`、verifier invoke `0`、summary 未获 outer held binding；但 failed-only
sidecar 没有实现“失败信息不再被遮蔽”的目标，下一候选必须修复并增加 validation-time/cleanup-time 分离证据。

## 持久失败证据

下列本机文件已设为 ReadOnly；它们位于 gitignored `.checks` 或 `${TEMP}`，不入库：

| 文件 | bytes | SHA-256 |
|---|---:|---|
| `.checks/tablet-c1b-real-build-smoke-21d2986.summary.json` | 2620 | `ac58b9a2917f403bbd3b974c690eb1f1edcb755de336539376ae160b5c2b7ba1` |
| `.checks/tablet-c1b-real-build-smoke-21d2986.log` | 1948 | `fc21964f0e666b305ca118cd8bc1390e2998ab70817797edee8ab79cb4e65c97` |
| `.checks/tablet-c1b-real-build-smoke-21d2986.launcher.json` | 4745 | `03d7126fe6388c35dc42db548f99240e20e8db62932e46b06c0d4f388b79bf26` |
| `${TEMP}/tl1-c1b-next-staging-template/launcher-21d2986.failure.json` | 2999 | `1ce8b6050e65eec97cb26982c06a7b5e76a63210566a915685212acac48b004a` |

summary 原始 2,620 bytes 加 CRLF 后与 launcher 捕获 stdout 的 2,622 bytes/SHA 完全一致；但 outer verifier 未调用，
所以该闭合只能证明失败诊断来源一致，不能成为 pass authority。helper repository-library cleanup 与 launcher 的
process/job/gate、file/directory guard、buffer cleanup 均为 completed/0 failures；workspace/journal/Java/ADB/listener
无新残留。module build residual 是启动前既有目录。

## 退出后隔离与后续边界

既有 build 树没有 tracked 文件、全部被 `**/build/` 忽略、无 reparse point，ACL 也没有残留 deny。为避免直接删除，
已把整个目录同卷移动到
`${QUARANTINE_ROOT}/agent-for-mobile-tablet-c1b-probe-build-c4e42667-20260829T201101Z`；移动前后文件数、目录数与
总字节完全一致，原 `app/tablet-c1b-probe/build` 路径现为 absent，可按需恢复。

`21d2986` 的唯一授权已消费，不得重跑或因预存目录已隔离而追溯改判。下一候选必须：

1. 修正 active-process count 为单一表达式并加 AST canary；分别记录 validation 与 cleanup snapshot；
2. 非零 helper 仍先 held-bind、核对 stdout 并验证 closed failed-summary schema，把 helper primary/reasons 写入 result 与 sidecar；
3. 把 module build output 的 preexisting-absence 纳入只读 preflight，避免再次把授权耗在 Gradle 前；
4. 形成新的 clean SHA、repo-external helper/launcher/preflight，完成静态复核与一次 read-only preflight；
5. 再由用户针对新 SHA 明确授权新的 build-only one-shot。install、ADB、设备与采集仍需后续独立授权。
