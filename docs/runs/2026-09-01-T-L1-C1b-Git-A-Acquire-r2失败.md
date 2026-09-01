# Git 恢复 `A-Acquire` r2 单跑失败

## 结论

- 用户授权精确绑定 parent SHA-256
  `04875b31db6b1743a5c6079d62bfe0cc5e727a8f1e8ceaa6b2a10909b061cba9` 与 leaf SHA-256
  `d7939294d6457848cdcddfe0f61e384caaf8855cf54eb1b3a099e8ae217f3003`，仅允许一次 `A-Acquire`。
- 该授权已消费：caller 只启动一次 parent，parent 只启动一次固定 PowerShell child；parent/child 均已退出，
  automatic retry=`0`，外部实际 exit=`1`，stdout/stderr terminal 均 closed。同一 pair 冻结，不重跑。
- leaf 已完成唯一 asset transfer，所得 installer 为 65388144 B，SHA-256
  `af12577d0fdff74243a5988197aa49b957d5044edc17004f6ddf0768996f1dca`，与冻结期望完全一致；installer 未执行。
- 失败发生在 `authenticode`。运行内 failure receipt 只记录 generic `Installer Authenticode contract failed.`；退出后对
  frozen leaf 的 exact `-Content` 调用重演才得到 `NotSigned/None`，另一次最终 native path `-LiteralPath` 只读复核得到
  `Valid` 及精确预期 signer。结合固定 PowerShell 7.6.4 的 IL/SIP 路径，这才确认是输入形态造成的 P1 false-negative，
  不是 receipt 直接披露了签名状态，也不是下载内容、hash 或发布者签名失配。
- leaf 已发布 closed failure receipt，输出目录保留 exact-two ReadOnly 证据；没有自动删除、清理或重试。
  本次 A 未通过，不放行 `B-Backup`，也不继承或产生 B/C/D/E 授权。

## 唯一运行窗口与 caller 证据

| 项 | 观察值 |
|---|---|
| UTC 窗口 | `2026-09-01T11:07:59.0208441Z` → `2026-09-01T11:08:11.5560200Z` |
| elapsed | `12535 ms` |
| parent start attempt / exit | `1 / 1` |
| parent PID | `46036` |
| outer timeout / retry | `false / 0` |
| stdout/stderr terminal | `closed / closed` |
| caller JSON parse attempts | `0` |
| caller cleanup/retry | `0 / 0` |

外层先于任何可选 JSON 解析固定三件 raw evidence，并将其设为 ReadOnly；证据目录只含以下三项：

| 文件 | 长度 | SHA-256 |
|---|---:|---|
| `parent.stdout.bin` | 39 B | `97c621c23ae8d627611d796130d812dc16beed1ce7a1f53e8c6cb951c43a9a4b` |
| `parent.stderr.bin` | 4341 B | `aee7e5c5bbb72e6f61e9fea261bda641c19600e94b6e3b14a2d7b832786d68c6` |
| `caller-summary.json` | 854 B | `d2353e07b4d1de73edd4f9a6fe244fe2cee91c1fbc1004e4a41c1e1ec101e96f` |

三项均为 ordinary、non-reparse、single-link、ReadOnly。parent stdout 的 39-byte 内容精确为
`System.Threading.Tasks.VoidTaskResult\r\n`：r2 对 `$exitTask.GetAwaiter().GetResult()` 的未接收返回值污染了 stdout；
它没有改变 child 或 parent exit，但新 parent 必须以 `$null = ...` 消除该非协议输出。

`caller-summary.json` 的最后两个 bytes 是字面 `5c 6e`（反斜杠与 `n`），不是 LF；其长度/hash 与上表冻结证据一致，
但直接 strict parse 会因 trailing additional text 失败，所以不能把它称为严格可解析 JSON。summary 自记
`parse_attempt_count=0`，该问题没有改变已先行固定的 raw stdout/stderr、exit 或 terminal，也不产生重跑权限。下一 caller
必须写真实 LF 或不加尾随字面，并增加 strict parse 门；解析失败仍只能记为 secondary，不能重启目标。

## parent 结构化失败

固定 PowerShell 7.6.4 对 parent stderr 的 JSON 解析成功。parent 发布
`git-for-windows-acquire-parent-result/v2` 的 closed failure：

| 字段 | 观察值 |
|---|---|
| terminal / pass eligible | `failed / false` |
| phase | `child_nonzero_exit` |
| primary type | `AgentForMobile.ChildExitCode` |
| child / authoritative / external exit | `1 / 1 / 1` |
| timed out | `false` |
| Job active / total / terminated | `0 / 1 / 0` |
| child stdout | `0 B` / SHA-256 `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` / EOF |
| child stderr | `556 B` / SHA-256 `82a4e647515c4a2cbccd5ea00ea5abf5bce094f84ea256039cfb91f48d250e8b` / EOF |
| success receipt / failure receipt / installer | `absent / present / present` |
| runtime watcher events/errors | `0 / 0` |
| failure-target watcher events/errors | `0 / 0` |
| secondary failures | `0` |

有界 stderr preview 成功暴露 leaf 的 failure receipt 名称、`failed_phase=authenticode` 与
`Installer Authenticode contract failed.`，没有再把首因压缩成仅 byte count/hash。parent result 的 primary、终态、
exit、receipt 与 installer 观察彼此一致。

## 输出与 failure receipt

专用输出目录退出后只含以下两个 ReadOnly artifact；不得删除、修改、清理或复用于新候选：

| 文件 | 长度 | SHA-256 | 文件约束 |
|---|---:|---|---|
| `Git-2.55.0.3-64-bit.exe` | 65388144 B | `af12577d0fdff74243a5988197aa49b957d5044edc17004f6ddf0768996f1dca` | ordinary / non-reparse / single-link / ReadOnly |
| `failed-download.receipt.json` | 1613 B | `3b2c7459b95e57f9801c238614188f4fa538d26326e40e1b657c84d523e49b8c` | ordinary / non-reparse / single-link / ReadOnly |

failure receipt 为 `git-for-windows-download-receipt/v1`，其机械结论为：

- terminal=`failed`、pass=`false`、installer_executed=`false`；
- failed_phase=`authenticode`，primary/cleanup/recording failure=`1/0/0`；
- redirect chain 精确为发布页的 `302` 到 release asset host 的 `200`；应用级 transfer/retry 均未发生第二次；
- receipt 与 installer 的 held identity/final-path 观察在 parent 消费时均闭合。

receipt 没有记录 `Status=NotSigned`、`SignatureType=None`、signer 或 timestamp；这些具体值来自退出后的 exact 调用重演，
不能追溯写成运行内 receipt 字段。

## Authenticode false-negative 复核

退出后围绕 exact installer 的两种只读调用给出确定性分歧：

1. exact 重演 frozen leaf 的 `Get-AuthenticodeSignature -Content $bytes -SourcePathOrExtension 'Git-2.55.0.3-64-bit.exe'`
   返回 `Status=NotSigned`、`SignatureType=None`，没有 signer 或 timestamp；
2. 同一文件经最终 native path 单次调用 `Get-AuthenticodeSignature -LiteralPath ...` 返回
   `Status=Valid`、`SignatureType=Authenticode`，signer subject 精确为
   `CN=Johannes Schindelin, O=Johannes Schindelin, L=Bruehl, C=DE`，issuer 为
   `CN=Microsoft ID Verified CS AOC CA 03, O=Microsoft Corporation, C=US`。

独立 path-based 复核还得到 signer certificate SHA-256
`1668941fff36fec818a596ffde6589f34daa6c6434069e60f356b7755f084e63`，有效期
`2026-07-09T02:00:34Z` 至 `2026-07-12T02:00:34Z`；timestamp 存在，timestamp certificate SHA-256
`d8b93c97648662bbbf7dfefe0f6aab26792cc1c61d2baa462aeec6186af8fecd`，有效期截至
`2026-10-22`。

固定 PowerShell 7.6.4 的 `-Content` 分支走 blob choice，并使用 PowerShell script SIP subject；
`-SourcePathOrExtension '.exe'` 不会把它切换到 PE embedded-signature SIP。`-LiteralPath` 分支走 file choice，
按文件类型派发，所以同一 PE 的命名路径复核能得到 `Valid`。因此不能把 `-Content` 的 `NotSigned` 当作该 installer
确实未签名，也不能仅通过放宽预期状态绕过验签。

## 旧 leaf 的实际 handle 状态与下一候选边界

旧 leaf 以 native CreateNew 建立 `GENERIC_READ | GENERIC_WRITE`、share=`READ` 的 writer-origin FileObject，完成 same-handle
写入、flush、hash/identity 与 ReadOnly 后，从同一 FileObject duplicate 出所谓 read guard，再关闭 writer wrapper。exact share
canary 证明：duplicate handle 仍保留 writer-origin `WriteAccess` share bookkeeping；它不是新开的 read-origin guard，存续时对
最终 native path 的 `-LiteralPath` 只读重开会稳定返回 `0x80070020` sharing violation。因此不能把旧 leaf 写成“关闭 write stream 后即可在
held guard 下命名重开”，也不能把退出后所有 writer-origin handles 都关闭后成功的 path-based 诊断外推到旧运行窗口。

同一 signed-PE canary 在完全关闭 writer FileObject 后，fresh `GENERIC_READ`、share=`READ` guard 经 stable ID/SHA 重验，
`-LiteralPath` 得到 `Valid`，post identity/SHA 不变；旧 leaf 对 pinned PowerShell executable 的检查本来就采用同类
read-origin final-native-path guard + `-LiteralPath` 并成功。该可用性 canary 的临时对象已精确清理，无残留。

旧 leaf 实际保留了 stable ID、ordinary/no-reparse、single-link、ReadOnly、最终 DOS/native path、held identity 与 pinned
SHA-256 门，但它在该 writer-origin duplicate 存续期使用的是 `-Content`，随后按 generic Authenticode failure 停止。当前
frozen parent r2、leaf r1、exact-two 输出与 caller evidence 全部保持原样，不修补、不清理、不重跑。

新的 leaf r2 已把以下安全流定稿并冻结：

1. writer-origin FileObject 必须在同一 handle 上完成 flush、hash、identity 与 ReadOnly，再关闭**全部** writer-origin
   handles；不能把其 duplicate 冒充 read-origin custody。
2. 关闭 writer-origin handles 到 read-origin 重绑之间存在必须诚实披露的短 rebind gap；
   `continuous_custody=false`、`preverification_rebind_gap=true`。
3. 任何 Authenticode 或后续 consumer 使用前，必须经 exact native path 新开 `GENERIC_READ`、share=`READ` 的 read-origin
   guard，并立即重新证明 initial stable ID、最终 DOS/native path、ordinary/no-reparse、link count=`1`、ReadOnly、长度与
   pinned held SHA-256；只有全部成立才可记 `authority_reestablished_before_use=true`。gap 内仍活跃的 writer 会让重绑失败；
   gap 内临时改动后恢复，也必须在任何消费前通过这次 exact authority 重建。
4. read-origin guard 保持 live 时才调用最终 native path `-LiteralPath`；`finally` 必须无条件执行 post-held identity 与
   SHA-256 复核。receipt 还须披露命名路径重开不是 held-handle-backed validation，native namespace 仍是外部边界。
5. parent v3 严格消费 transfer/installer/evidence 的 `6/40/26` 个键，以
   `$null = $exitTask.GetAwaiter().GetResult()` 消除 stdout 污染，并保留固定 Bypass argv、failure preview、primary-first 与
   r2 的其余 identity/terminal 门。

下一候选已使用新的 exact-empty 输出目录并完成冻结：

| 工件 | 冻结状态 |
|---|---|
| leaf r2 `download-git-2.55.0.3-x64-r2.ps1` | 78484 B / 1651 行 / Parser0 / ReadOnly / SHA-256 `a78c99e499992ec802b42ced541df6112faecfcd3636fde183499206ae2ecd66` |
| parent r3 `launch-download-git-2.55.0.3-x64-r3.ps1` | 141536 B / 2936 行 / Parser0 / ReadOnly / SHA-256 `fd7d9b6d83c4e36024fbda9214fd1541bfc08f989b887bf80764bdcf06bb2a25` |

二者均 ordinary、non-reparse、single-link；两路 parent 审计与此前三路 leaf 审计的 P0/P1/P2 均为 `0/0/0`。新 pair
尚未授权、未执行；旧 r1/r2 pair 的授权已经消费，均不得复用或重跑。下一动作只允许请求一份同时绑定上述两个完整
SHA-256 的新一次性 `A-Acquire` 授权；A 若闭合也只把下一动作变成申请 `B-Backup`，B/C/D/E 不继承。

下一 caller 的 exact-empty evidence 目录已保留，但 caller 脚本尚未冻结。任何执行前必须确认 summary 使用真实 `0x0A`
或 EOF、先固定 raw stdout/stderr/exit/terminal、严格写后回读解析；解析失败只能成为 secondary，不得启动 retry。caller
尚未冻结不改变 exact pair 已可请求授权，也不构成执行权限。

## 退出后独立只读复核

- 递归构造并排除 caller 全部祖先后，parent PID 已不存在、后代=`0`，非祖先的 parent/leaf/output/installer 标识目标
  进程=`0`。先前未排除调用链自身的宽泛命中不属于 A 启动的目标进程证据。
- 固定 PowerShell runtime 独立完整复算仍为 983 files / 54 dirs / 296034085 B；file catalog 为
  `038b2a680cf375d6fdc8b718a7895d64812700d78a737ea3243808f77be1b225`，directory catalog 为
  `295b0a0246e83c4a6e8e2f0da7469afe839b7144e9a9d688bb8b0c54c46313df`，全树 ordinary/non-reparse，
  与运行前完全一致。
- 当前 exact-two output 与 exact-three caller evidence 继续只读冻结；本次检查没有执行 installer、自动清理或重试。
