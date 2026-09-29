# C1b exact pair / r14 源码准备

`scripts/prepare-tablet-layout-c1b-candidate-source.ps1` 将冻结的 r12 renderer、helper/launcher
模板和 r13 leaf 转换为可审查的新候选源码。它不执行 renderer、preflight、helper、launcher、Git、构建或 ADB。
入口输出是 `.checks/c1b-candidate-source/<short>/` 中的 **review drafts**，不是已冻结工件、clean SHA 证明或运行授权。

## 输入与步骤

1. 完成所有代码修改、常驻离线门和最终 clean SHA 固定，再提供完整 40 位 SHA。
2. `C1B_FROZEN_SOURCE_ROOT` 指向已有 repo-external staging，须保留
   `render-final-r12-015835c.ps1`、`helper-template.ps1`、`launcher-template-r11.ps1`、
   `preflight-a661f36-r13.ps1`。实际发布 pair 时还需要 renderer 既有的历史 r10 pair、template 与 failure sidecar。
   不复制冻结生成物入库，不修改它们；源缺失时先恢复精确冻结输入，不接受当前内容的新 hash。
3. 使用钉定的 PowerShell 7.6.5 执行下面的源码准备命令。入口检查 exe hash；Utility DLL 的 hash 和长度也固定，
   不能使用自更新缓存中的同名运行时。

```powershell
$pwshPath = Join-Path ${env:REPOS_ROOT} '_toolchain/powershell-7.6.5/pwsh.exe'
& $pwshPath -NoProfile -File scripts/prepare-tablet-layout-c1b-candidate-source.ps1 `
    -FrozenSourceRoot ${env:C1B_FROZEN_SOURCE_ROOT} `
    -CommitSha ${env:C1B_FINAL_COMMIT_SHA} -PwshPath $pwshPath
```

输出包括 pair renderer、r14 renderer，以及 helper/launcher/preflight 三份 `.expected.ps1`，供独立 hash/AST 对照。
同名目录已经存在时拒绝覆盖。输入 raw index 在派生前后复核；入口不启动 Git，故 **不声称工作树干净**。
新 SHA 或任何影响输入的改动都必须重新定版，不能把占位 SHA 的适配测试当作最终候选。

4. 静态审查这五份源码及输入绑定。pair 的历史对照先逐字节重现上一对冻结 hash；常量只按唯一顶层变量名改写，
   相同值的历史常量保持不动。launcher 原模板仍按旧 hash 读取；转换包含三处精确 `7.6.4 → 7.6.5`、
   bootstrap 最早抑制进度输出、stderr 有界原始前缀诊断，以及两处捕获数组按真实引用清零。
   新 helper 的唯一 Gradle 调用还显式启用 `FailureDiagnostics`，wrapper 只透传该开关；
   转换器与生成 renderer 复用相同两处精确改写，历史模板/hash 对照仍在改写前核验。
   helper 的七项 `expectedLibraryHashes` 必须取最终 `RepoRoot` 的原始文件字节，并精确替换唯一顶层 literal map；
   verifier 的本轮 raw hash 同时绑定 launcher、pair/r14 renderer 与 preflight，不能沿用历史模板内的仓库源码 hash。
   七项 map 的键、顺序、数量和 `sha256:` 小写值必须完全符合 loader 合同；新 renderer 与内存派生共用同一转换。
   内存派生和实际 renderer 复用同一份转换清单，各转换核验精确出现次数；r14 逆向模板 hash 对应转换后的模板。
5. 将通过审查的 renderer 作为新的独立 exact artifact 冻结，再运行 **仅生成工件** 的 pair renderer，之后才是 r14
   renderer。二者复用原 r12 bootstrap/no-follow held input/stable-ID/final-path/same-handle rename/no-replace
   发布原语，最终 helper/launcher/preflight 必须与 `.expected.ps1` 的 hash/length 一致。本入口不会自动执行这一步。
6. 新工件独审闭合之后，read-only preflight 和 build-only one-shot 仍依原有顺序各自处理；本次源码准备不替代这些门，
   不授权设备操作。见 [C1b runbook](T-L1-tablet-layout-c1b-v1.md)。

**BuildOnly 启动令牌门：** 申请绑定本轮完整 SHA 的单次授权前，先用钉定 PowerShell 做一次不调用
launcher、Git、构建或 ADB 的 UAC 探针，并保存提升后进程内的管理员令牌检查结果。正式 one-shot 的
launcher 也必须由已提升的 PowerShell 进程启动（例如由 `Start-Process -Verb RunAs` 启动的子进程）；
只检查未提升的外层调用方或只出现 UAC 提示均不足以证明这一条件。正式子进程在调用 launcher 前再次执行：

```powershell
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'BuildOnly launcher requires an elevated token.'
}
```

获得单次授权后，先逐字节读回 launcher 的 64 位小写 SHA-256，并在**该提升后的子进程**启动命令中
显式传入其唯一 mandatory 参数：

```powershell
& $pwshPath -NoProfile -File $exactLauncherPath -ExpectedLauncherSha256 $readBackLauncherSha256
```

命令审阅时必须同时核对提升后的令牌、`-File` 的本轮 exact 路径和该参数的值；启动失败也记录为
本轮失败尝试，不在同一固定候选补参或提权重跑。此前 `7c55116` 的唯一调用正因漏传该参数在脚本主体前失败，见协调来源的
`docs/runs/2026-09-28-C1b-7c55116-BuildOnly参数绑定失败.md`；它不构成构建通过或新授权。

固定候选须使用独占工作目录。现有 r14 host 模板要求普通 `.git` 目录及本地
`codex/security-hardening` 的 HEAD/loose ref；普通 worktree 的 gitfile 不满足这一层合同。
需要隔离时可使用完整 local clone（`--no-hardlinks`，不使用 shallow/filter/shared/alternates），
只在新 clone 中把该本地分支指向新候选。按新 clone 的实际字节完成完整门、清理本轮构建状态、
固定 clean/index 后再生成新工件；不复用旧目录的 raw index 或把旧 host 工件改路径后重跑。
独审同时核对这八项源码 hash 与最终目录的原始字节。普通 clone 的 LF/CRLF 可能与开发目录不同，
即使 Git blob 相同也不能复制另一目录的 raw hash；此前 `0386ee7` 的七项 loader 中实际有五项与旧模板不同。

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

两个常驻回归使用最小 synthetic fixture；不依赖历史 staging、本机账户路径、Git 安装树或真实设备。
源码回归为 14 个用例，包含 4 个无害 bootstrap 子进程，验证进度噪声抑制且真实错误仍被拒绝，
另校验 helper 的有界失败诊断与生成端一致、七项 literal map 的拒绝门，以及最终文件的原始字节读取；
r14 回归为 1300 条断言、28 个变异拒绝（其中输出流合同 18 个），不启动外部进程。
测试还覆盖源码 AST 精确改写、pre/finally-post 故障顺序，以及真实 Windows no-follow handles、内部/外部 hardlink、
空文件、reparse、catalog/identity 漂移与字节 canary。真实冻结输入的派生适配测试另行执行，只能证明源码能够生成和通过 Parser，
不能升级为真实 preflight 或 smoke 通过。
