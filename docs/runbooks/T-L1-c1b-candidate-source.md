# C1b exact pair / r14 源码准备

`scripts/prepare-tablet-layout-c1b-candidate-source.ps1` 从
[`scripts/lib/c1b-candidate-source/`](../../scripts/lib/c1b-candidate-source/SOURCE.md)
中的受版本控制维护源确定性生成可审查的新候选源码。该目录记录四份源的迁移对照和当前绑定。
旧 r10/r11/r12/r13 冻结文件仅作为只读回归对照，不是新候选输入。入口不执行 renderer、
preflight、helper、launcher、Git、构建或 ADB。
入口输出是 `.checks/c1b-candidate-source/<short>/` 中的 **review drafts**，不是已冻结工件、clean SHA 证明或运行授权。

## 输入与步骤

1. 完成所有代码修改、常驻离线门和最终 clean SHA 固定，再提供完整 40 位 SHA。
2. `C1B_STAGING_ROOT` 指向已准备的 repo-external 候选输出目录，`C1B_GIT_PATH` 指向本轮核定的
   `mingw64/bin/git.exe`；helper 另核验同一 Git 安装树的 `cmd/git.exe`。四份维护源、r14 检查源、
   verifier、PowerShell 及 Utility DLL 是受控输入；
   维护源 hash 在转换函数中固定，准备记录列出本轮输入 hash。helper 的七份库（c1a、validator、c1b、artifact、
   aapt2、build、runner）按最终仓库实际 raw bytes 重算，保持唯一顶层 ordered map 的键序、数量和小写 hash，
   派生前后复核并纳入 source_inputs。旧冻结工件不参与新 pair 的发布门。
3. 使用钉定的 PowerShell 7.6.5 执行下面的源码准备命令。入口检查 exe hash，Utility DLL
   的 hash 和长度也固定；不能使用自更新缓存中的同名运行时。

```powershell
$pwshPath = Join-Path ${env:REPOS_ROOT} '_toolchain/powershell-7.6.5/pwsh.exe'
& $pwshPath -NoProfile -File scripts/prepare-tablet-layout-c1b-candidate-source.ps1 `
    -StagingRoot ${env:C1B_STAGING_ROOT} -GitPath ${env:C1B_GIT_PATH} `
    -CommitSha ${env:C1B_FINAL_COMMIT_SHA} -PwshPath $pwshPath
```

输出包括 pair renderer、r14 renderer，以及 helper/launcher/preflight 三份 `.expected.ps1`，供独立 hash/AST 对照。
同名目录已经存在时拒绝覆盖。输入 raw index 在派生前后复核；入口不启动 Git，故 **不声称工作树干净**。
新 SHA 或任何影响输入的改动都必须重新定版，不能把占位 SHA 的适配测试当作最终候选。

4. 静态审查这五份源码及输入绑定。所有候选常量按唯一顶层变量名改写；维护模板不含历史候选、本机
   路径或旧 SHA。launcher 维护源已包含 7.6.5、最早抑制 progress、stderr 有界原始前缀诊断及
   两处捕获数组按真实引用清零。helper wrapper 将 FailureDiagnostics 透传至唯一 Gradle 调用；实际 pair renderer
   执行同一七库绑定与诊断转换，发布 bytes 必须与 expected helper 一致。pair renderer 仅读取本仓库的 helper/launcher 模板及当前 verifier、
   钉定运行时，逐份检查准备时嵌入的 hash；r14 renderer 另核验本仓库 preflight 维护源的精确路径及 hash/长度，
   并持有其父目录链。维护源不要求位于 staging；发布产物和已冻结 pair 仍必须是 staging 的直接子项。
   若维护源发生有意变更，必须更新源码 hash 绑定、完成离线回归并重新固定候选。
5. 将通过审查的 renderer 作为新的独立 exact artifact 冻结，再运行 **仅生成工件** 的 pair renderer，之后才是 r14
   renderer。二者沿用已审查的 bootstrap/no-follow held input/stable-ID/final-path/same-handle rename/no-replace
   发布原语，最终 helper/launcher/preflight 必须与 `.expected.ps1` 的 hash/length 一致。本入口不会自动执行这一步。
6. 新工件独审闭合之后，read-only preflight 和 build-only one-shot 仍依原有顺序各自处理；本次源码准备不替代这些门，
   不授权设备操作。见 [C1b runbook](T-L1-tablet-layout-c1b-v1.md)。

## BuildOnly 启动门

申请绑定本轮完整 SHA 的单次授权前，先用钉定 PowerShell 做不调用 launcher、Git、构建或 ADB 的
UAC 探针，保存提升后进程内的管理员令牌检查结果。正式 one-shot 的 launcher 也必须由已提升的
PowerShell 进程启动；仅出现 UAC 提示或仅检查外层调用方均不足以证明该条件。正式子进程在调用前再次核验：

```powershell
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'BuildOnly launcher requires an elevated token.'
}
```

获得本 SHA 单次授权后，逐字节读回 launcher 的 64 字符小写 SHA-256，在该提升后的子进程中显式传入
唯一 mandatory 参数；审阅时同时核对本轮 exact `-File` 路径、参数值和令牌：

```powershell
& $pwshPath -NoProfile -File $exactLauncherPath -ExpectedLauncherSha256 $readBackLauncherSha256
```

启动失败也封存为该候选的失败尝试，不在同 SHA 补参或提权重跑。

### 后续候选的外层双流证据

`scripts/lib/c1b-host-process-capture.ps1` 提供纯主机一次性采集函数
`Invoke-TL1C1bHostProcessCapture`。调用方先绑定 exact executable、参数、工作目录、输入及授权，
并在需要时取得已提升令牌；该函数不会选取候选、提升权限或授予设备许可。
证据目录必须不存在，以 `CreateNew` reservation 拒绝重复启动。Windows 子进程先挂起，
限制继承句柄并加入 kill-on-close Job 后才恢复；分别读取 stdout/stderr 原始字节，记录真实 EOF、
观察总量、完整 hash 及有界前缀。默认运行限时 45 分钟，每路前缀上限 1 MiB，
drain 与 cleanup 各有 30 秒期限。溢出、非零退出、超时、drain 或清理失败均拒绝通过。

调用方必须检查返回的 `status`；函数返回不代表子进程原生退出码为零。
`exit_code`、自然退出、两路 EOF 及 Job/句柄清理各自记录，未观察到完整流时总量/hash 为 null。
采集通过只证明本次传输与清理合同，正式主机合同仍须独立读回与审查。
该工具尚未接入固定候选发布/UAC 启动链；不能用它补写历史合并输出的 EOF 或重跑已消费的 one-shot。

```powershell
. scripts/lib/c1b-host-process-capture.ps1
$capture = Invoke-TL1C1bHostProcessCapture -ExecutablePath $pwshPath `
    -ArgumentList $reviewedArguments -WorkingDirectory $boundWorkingDirectory `
    -EvidenceDirectory $freshEvidenceDirectory
if ($capture.status -cne 'passed') { throw '主机外层捕获未通过。' }
```

常驻回归 `scripts/tests/c1b-host-process-capture-offline.ps1` 包含 13 个场景、104 项断言：
二进制双流、空流、非零退出、溢出全量 hash 与有界前缀、stdout EOF 后继续写 stderr、
运行超时、root 先退出而 descendant 留存、重复证据拒绝、Windows 参数及 stdin EOF、启动失败，
以及显式空/替换/叠加环境、Unicode、父环境不变和非法环境键值的启动前拒绝。
测试只运行合成主机进程，不调用 Git、JDK/Gradle、BuildOnly 或 ADB/设备。
此回归已纳入 `scripts/check.ps1` 的 C1b 候选生成与预检门。

`scripts/invoke-c1b-candidate-host-stage.ps1` 是新候选的主机阶段入口。Run 消费 caller-pinned bindings 与状态材料，
核对 runtime、源码、精确 argv、cwd、环境和工件 inventory，再启动一个被 Job 包含的主机进程。
Read 从 native no-follow held bytes 独立复核 observation、两路流、reservation、输入与输出，
明确不声称观察到自身最终退出。调用方必须另捕获 Run 与 Read 进程并记录真实 native exit/PID。
状态材料是调用方审定证据，不替代 clone/freeze 的实物验证；已消费候选禁止进入该入口。
专项实际 10 个场景、81 项断言，包括六阶段合成执行、独立 Read、重复/漂移/错误类型和 native guard 反例。
这些合成结果不构成新固定候选验收。

## r14 新增门与离线回归

`scripts/lib/tablet-layout-c1b-preflight-r14-checks.ps1` 是可跟踪注入源，只定义函数。
Git 树按现有 build guard 的 UTF-8/LF/Ordinal catalog 规则校验 `9576` 文件、`9489` identities、`85` 内部 hardlink groups
及固定 catalog；拒绝树外 hardlink、reparse 和路径/identity/content/membership 漂移。单次 snapshot 持有整棵树的目录与文件
no-follow handle，完成复核后释放。主流程在第一条只读 Git 前执行一次，主 `finally` 再执行一次；后置失败只记录，保留
primary-first，最后汇总拒绝失败终态。额外 identity catalog 对比保留前后树拓扑。离散 pre/post 不声称排除期间的瞬时变化。

launcher 的 held-byte reader 只接受唯一 `return ,$bytes` AST。运行时 canary 在隔离 runspace 执行已验证的固定 return，
用 0/1/5 字节向量核验返回类型、内容和 CRLF framing，不加载或调用 launcher 本身。

输出流合同还核验 bootstrap 的 `ProgressPreference=SilentlyContinue` 位于 `ErrorActionPreference=Stop` 之前，
保留 stderr 非空、溢出及 drain 失败的拒绝门。原有 launcher 日志增加最多 1 MiB 原始 stderr 前缀的 Base64、
前缀 hash/长度和未捕获长度；全流 hash/总长度继续独立记录，不能将前缀当作完整 stderr。
捕获数组清零必须保留真实 `byte[]` 引用，避免 PowerShell 管道枚举后只清掉副本。

```powershell
& $pwshPath -NoProfile -File scripts/tests/tablet-layout-c1b-candidate-source-offline.ps1
& $pwshPath -NoProfile -File scripts/tests/tablet-layout-c1b-preflight-r14-checks-offline.ps1
```

两个常驻回归使用 synthetic fixture，并对版本控制的维护源做确定性派生；不依赖历史 staging、
本机账户路径、Git 安装树或真实设备。源码回归包含 4 个无害 bootstrap 子进程，
验证进度噪声抑制且真实错误仍被拒绝；另用钉定 PowerShell 7.6.5 的冷 CLI 实际执行合成 pair renderer，
核验发布字节与 expected pair 相同、只读，以及同一夹具再次执行时拒绝覆盖且原字节不变。
夹具只生成被忽略的 helper/launcher，不运行它们、构建或设备操作；
r14 回归为 1300 条断言、28 个变异拒绝（其中输出流合同 18 个），不启动外部进程。
源码回归共 16 项，还核验 helper 七库 raw hash、FailureDiagnostics 透传、renderer/expected bytes 一致和 LF/CRLF；
动态、嵌套、重复、错序或不完整库绑定均拒绝。回归执行生成 r14 的路径检查和目录链清理控制流，覆盖仓库维护模板、错误模板路径、staging 子项逃逸及
源父目录获取失败；r14 夹具用内存句柄替身，不发布工件。Pair/r14 生成的模板与 verifier 路径还实际覆盖 Windows 的不同盘符、中文及空格目录，
原混合斜线和父目录跳转仍由未放宽的 lexical-canonical guard 拒绝。测试还覆盖源码 AST 精确改写、pre/finally-post 故障顺序，以及真实 Windows no-follow handles、内部/外部 hardlink、
空文件、reparse、catalog/identity 漂移与字节 canary。维护源的派生测试只能证明源码能够生成和通过 Parser，
不能升级为真实 preflight 或 smoke 通过。
