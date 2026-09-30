# T-L1 C1b `a661f36` real build-only smoke 失败

## 结论

- fixed SHA：`a661f365322bbb8ef3aa83f7a84b9bcb23a51f6e`
- 唯一 launcher 窗口：`2026-08-31T22:44:54.1615053Z` → `2026-08-31T22:55:07.6656587Z`
- 整体结论：**失败并冻结，不自动重试。** launcher/helper start 均为 `1`、exit 均为 `1`，automatic retry `0`；
  外层实际观察 exit `1`。
- helper 在 Gradle 前因 Git file count 不一致而 fail-closed；退出后独立只读重算才确认 full-tree catalog 也漂移。
  launcher 随后又因 `Byte[]` 被 PowerShell pipeline 展开成 `Object[]`，在 summary framing 的 `Buffer.BlockCopy`
  处失败并遮蔽 helper primary。
- GradleMain、ApkSigner、aapt2、held Git、ADB、设备枚举、install、T0 与采集均为 `0`；本轮不能评价 commit 的
  Android build 是否成立。
- 授权边界只有 build-only smoke；没有执行 ADB 命令、设备发现、install 或真机访问。

## 授权前 read-only preflight

r13 leaf 仅运行一次，外层 exit `0`、terminal `closed`、primary/cleanup/recording 均为 `0`；四次只读 Git 全部闭合，
三阶段被动观察的 `adb.exe` / TCP/5037 均为 `0/0`。它没有启动 launcher/helper/build/ADB/设备。

| 对象 | SHA-256 |
|---|---|
| preflight r13 leaf | `bf15d0097fa02c9c99f69f8b08b5415390728bfb3d054b84bbd7895abafcd57c` |
| preflight r13 receipt | `55524bc831efebc04f5c6464ee4cb1afe0ed2c157021ab53348a3084d067b010` |
| launcher r10 | `a022c356f6297f2e60fd110eecce34a2f10d990c09e300db82eed52eb5e5fefe` |
| helper r10 | `5f13f4448b35223121af08b8b8a6bde457439cf88b87d50a9b6429d619b0e7d0` |
| verifier | `daf9703c53177e5a3f592ac38a71ccb1271dd6c802220f01c12edb59143766fa` |
| PowerShell 7.6.4 | `db6dd81183fe57d22e03b911ec9a30a2fd7c40542e97743615355a6fb44f458f` |

手机套件已按用户明确授权精确关闭；启动前再次确认 ADB/5037 为 `0/0`。launcher 经固定 PowerShell 7.6.4、
`-NoLogo -NoProfile -NonInteractive`、固定 working directory 与一次 UAC RunAs 启动；没有第二次 launcher 或重试。

## helper 首因：Git trust root 冻结绑定漂移

helper 在 build-environment guard 中先看到 file count 不一致：

```text
primary: C1b Git for Windows 2.55.0.windows.3 installation file count 必须 exact 9576。
```

退出后以与生产实现相同的只读算法独立重算 `${PROGRAMFILES}/Git`：

| 项 | 冻结值 | 当前值 |
|---|---:|---:|
| file count | `9576` | `9577` |
| catalog SHA-256 | `4c5e585b10f371f181b42b60948a883409c0efda910b869ff98c2e5604267458` | `deeaa4c2f51603d56cf7477fc413d0b9b914f58450431fbb6921f392ccc134ee` |

额外观察到 `etc/mtab` 是 38-byte MSYS 文件式 symlink 表示，SHA-256
`a4ae02c5b911f6d8d47a2ba1336807ec055217b5c01b12c497fadea11f140d16`。但只在内存 catalog 中排除它后，
count 虽恢复 `9576`，catalog 仍为 `556e52b3e4836e787a3cedc0ccf01c26392cf10b56824236357e11e03babf838`，不等冻结值。
因此不能把失败简化为一个可删除文件，也不能只把 expected count 改成 `9577`；除 `mtab` 外仍有至少一处路径或字节漂移。
六个 key files 与 `git.exe` 版本仍匹配，但缺少旧逐路径 manifest，当前证据不能安全定位全部差异。

安全后续只能是：从可信来源恢复 exact Git for Windows `2.55.0.windows.3` 并证明全树回到
`9576 / 4c5e…7458`；或对可信干净安装形成新的逐路径 catalog、identity/hardlink topology 与来源审计后再重基线。
不得直接删除 `mtab`、接受当前总 digest 或只放宽 file-count 门禁。

只读介质调查没有在常见 installer/cache 位置找到可确认的 `.windows.3` setup；现有卸载器声明 `NoRepair=1`。唯一
portable 候选不是 installer；相邻解压树是 `.windows.1`，且包自身版本资源不能证明它是目标 `.windows.3`，因此也不能
作为恢复介质。官方 immutable release
[`v2.55.0.windows.3`](https://github.com/git-for-windows/git/releases/tag/v2.55.0.windows.3) 公布的 x64 setup 是
`Git-2.55.0.3-64-bit.exe`，SHA-256 `af12577d0fdff74243a5988197aa49b957d5044edc17004f6ddf0768996f1dca`。
当前只完成了来源与 checksum 的只读确认；未下载、未执行。下载、验证 Authenticode 与机器级恢复必须分别纳入后续明确授权。

## launcher 二次遮蔽：数组返回类型丢失

helper 已发布合法 closed failed summary，stdout 也确实是 summary bytes + 一个 CRLF：

- summary：`2528` bytes，SHA-256 `ea8aae9ebc14635e79d307a233ff043685fbfba5cde2c966b48aecef2c315e15`
- summary + CRLF / captured stdout：`2530` bytes，SHA-256
  `bc1cc943df642bad6d43e8c086c4ff4f9ce006dd969e3f4c583103c3e203da0c`

退出后用固定 PowerShell 7.6.4 对冻结 summary 单独运行同一 strict JSON、exact-property 与 closed-failure validator，
`failure_count=2` 获接受；这证明 summary 本身结构合法。launcher result 中的
`summary_parse_attempt_count=0` / `failure_summary_accepted=false` 仍保持原样：本次 launcher 在到达这些门之前就抛错，
不能把事后验证改写成运行期已经接受。

`Read-LauncherHeldFileBytes` 内部建立了 `System.Byte[]`，但以 `return $bytes` 返回。PowerShell 函数输出管道会枚举数组，
调用点普通赋值后得到的是元素为 Byte 的 `System.Object[]`；`Buffer.BlockCopy` 因 source 不是 primitive-element array
确定性抛出：

```text
Object must be an array of primitives. (Parameter 'src')
```

failure-only sidecar 记录 `phase=summary_verification`、launcher line `2425`；summary parse/invoke 都是 `0`，所以 helper
的 Git primary 被 launcher 错误遮蔽。该缺陷对任何多字节 passed/failed summary 都必现，是 fail-closed 的 P1 false-negative，
不是本轮 Git 漂移独有。

最小源修是 launcher template 中唯一成功返回改为 `return ,$bytes`；生成 leaf 不能直接手改。Parser 将这里表示为
单元素 `ArrayLiteralAst`，不是 `UnaryExpressionAst`。新 renderer/preflight 必须增加 exact AST 门和隔离运行时 canary，
覆盖 1 byte、多 byte、passed/closed-failed summary，证明返回 exact
`System.Byte[]`、held bytes/hash 不变、`BlockCopy` 与唯一 CRLF framing 成功，并用 mutation 负例拒绝普通 return/cast/`@()`。

## 持久失败证据

下列本机文件已验证 ordinary/non-reparse 后设为 ReadOnly；它们位于 gitignored `.checks` 或 `${TEMP}`，不入库：

| 文件 | bytes | SHA-256 |
|---|---:|---|
| `.checks/tablet-c1b-real-build-smoke-a661f36.summary.json` | 2528 | `ea8aae9ebc14635e79d307a233ff043685fbfba5cde2c966b48aecef2c315e15` |
| `.checks/tablet-c1b-real-build-smoke-a661f36.log` | 2375 | `5b6614c95ffb9aabd34fdf4a6d3590110f58b5cf7711018793318fa6bde2f4b8` |
| `.checks/tablet-c1b-real-build-smoke-a661f36.launcher.json` | 5373 | `92a94b8724d78863dc577a533b8eb7b59417ac8c79fc69e730e438506c7be966` |
| `${TEMP}/tl1-c1b-next-staging-template/launcher-a661f36-r10.failure.json` | 3260 | `7ab1969bf3926f89f90d0b2cbeb20ea384a79796f8f336216b8d8ac0a14ba961` |

launcher result 为 `status=failed`、pre-publication pass closure false；外层 exit `1` 且进程退出后 sidecar 存在，因此绝不满足
“external exit `0` 且 sidecar absent”的成功权威。同 SHA 的授权已经消费，不得追溯改判或重跑。

## 退出后副作用审计

- helper 自然退出；root exit confirmed、Job validation/cleanup active count 都为 `0`，stdout/stderr drain 完成；
- launcher/helper PID 已消失，process/job/gate、文件/目录 guard 与 sensitive-buffer cleanup 全部完成，cleanup failure `0`；
- module `build`、workspace、recovery journal、module Gradle 与 `local.properties` 均无残留；HEAD 与 raw index 未变化；
- pre/post ADB process/listener 都为 `0`，device enumeration/install/T0/capture 均为 `0`。

## 后续边界

1. 保留 r10 pair、r13 leaf/receipt 与本轮四件失败证据，不修改、不复用授权。
2. 从 launcher template 生成新 revision，修复 exact `Byte[]` return；renderer 与 preflight 同时加入静态和隔离 runtime canary。
3. 下一 read-only preflight 在申请 smoke 前还要验证 Git trust root 的冻结 file-count/catalog；新增 trust-tree 核验本身
   不执行 `git.exe`、不启动 build，并且必须先于既有四次 repo 只读 Git 检查。环境漂移必须消耗 preflight，而不是再
   消耗 one-shot。
4. Git 安装恢复/重装或安全重基线属于主机变更，须使用可信来源并另行明确授权；不得以删除单文件代替。
5. 更新状态文档后固定新的 clean commit、raw index 与 exact external artifacts，独立静态复核并只运行一次 read-only
   preflight；只有它闭合后才可针对新完整 SHA 另行取得一次 build-only smoke 授权。
6. install、ADB 命令、设备发现、C1b 采集及 navigation/conversation/target/regions/layout/微信/editor/action/P0/execution
   继续不放行。
