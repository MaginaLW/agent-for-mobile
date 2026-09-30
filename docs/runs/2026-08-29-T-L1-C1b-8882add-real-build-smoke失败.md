# T-L1 C1b `8882add` real build-only smoke 失败

## 结论

- fixed SHA：`8882add6116ebd3cca547d865f9d142bbbcac1a4`
- 唯一授权窗口：`2026-08-29T10:54:50.0025967Z` → `2026-08-29T11:22:55.2835548Z`，共 `1685.281s`
- 整体结论：**失败并冻结，不自动重试。** launcher exit `1`；helper start `1`、exit `0`，automatic retry `0`。
- 边界结论：**build-only core 通过，但 launcher/evidence closure 未通过。** 因此外层 one-shot 不能记为 smoke 通过，`8882add` 不得进入设备授权。

## build-only core

helper summary 为 `status=passed`、`failure_count=0`，并绑定当前 clean HEAD、helper hash 与 42-file repository input catalog：

- bootstrap Git `2`，pre/post provenance 均为 `true`；repository inputs `42`、directory roots `3`；
- JDK/GradleMain `1`、ApkSignerTool `1`、held aapt2 `4`、held Git `32`；unexpected direct process `0`；
- artifact proof、dependency allowlist、packaged AXML exact-tree 与 post-Gradle lock seal 均通过；forbidden/mutating/extra component 均为 `0`；
- direct ADB attempt、observed ADB process start、real ADB call、设备枚举、安装、T0、采集均为 `0`；pre/post `adb.exe` 与 TCP/5037 listener 均为 `0`；
- artifact/build-environment/repository-library cleanup 均为 `completed`；workspace、journal、module build、module `.gradle`、`local.properties` 与 C1b Java residual 均为 `0/false`。

退出后另行只读复核同样得到 `adb.exe=0`、TCP/5037 listener `0`、Java `0`，且 module build、module `.gradle` 与 `local.properties` 均不存在。

## 外层失败根因

helper 原子写出的 summary 中，`started_at_utc`、`completed_at_utc` 与 `process_start_observation_ended_at_utc` 都是合法的 JSON string。launcher 先用固定 PowerShell `7.6.4` 的 `ConvertFrom-Json` 读取；该命令把三项 ISO 时间自动转换成 `System.DateTime`，随后 verifier 又要求它们必须仍为 nonempty `string`，因此在第一项报：

```text
Helper summary property is not a nonempty string: started_at_utc
```

这是确定性的 launcher 类型检查假阴性，不是 helper、Gradle、artifact、签名或 cleanup 失败。launcher 仍按 fail-closed 返回 `1`；不能因为 core summary 为 passed 就绕过 evidence closure。

下一候选须让 strict reader 显式保留 JSON 日期字符串（固定 PowerShell 已提供 `ConvertFrom-Json -DateKind String`），并增加一条由**实际 launcher verifier**消费合法 summary 的回归；不能只测 helper 内部 parser/canary。完成离线回归、全门与独立审查后固定另一 clean SHA，再另取一次 build-only smoke 授权。本轮授权、输出与临时 artifact 均不可复用。

## 持久证据

六个原始、字节一致的文件已复制到 gitignored 的本机证据目录
`docs/runs/evidence/tl1-c1b-8882add-real-build-smoke-20260829t105452z/`；其中 launcher 保留本机路径，故不得入库：

| 文件 | bytes | SHA-256 |
|---|---:|---|
| `preflight.json` | 3375 | `4e4ea575cf1a2583e035e4b54397990ffa443ebab38598db85767ceaceaf5a40` |
| `helper.ps1` | 50679 | `be4d2afa0e48aa1492eae870b5df6bfa9913a518a70770b0f46e64f4315014c9` |
| `launcher.ps1` | 32842 | `8d8932a5d09bdaaa9fafe3bf32b8413b8b86a61ebf3318e7cfc9676137ca2d68` |
| `summary.json` | 2998 | `ec4d8ed153e9ca95448084099122e3eba227dcf6e74d70a145e31d6d3f1b0715` |
| `launcher-log.json` | 4545 | `d856b8199628c2f1a486cc0a2044b9d80d855114425be67e3053270776386301` |
| `launcher-result.json` | 1145 | `c7fdf400d969c56b0db8ffcda84ae59c8dd47d6b9aea2837fbe70a8991e24f88` |

launcher log 中解码出的 stdout 与 `summary.json` 原始 bytes 加末尾 CRLF 完全一致；长度、hash、helper/launcher hash 与 launcher result 的绑定自洽。ADB 观测仍只是 host-wide best-effort WMI 加 5037 边界快照，不应表述为内核级形式化证明。
