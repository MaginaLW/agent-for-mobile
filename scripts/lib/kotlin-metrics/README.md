# Kotlin 函数指标

在仓库根目录，用项目已核验的 PowerShell 和 JDK 17–21 运行：

```powershell
& '<PINNED_PWSH>' -NoProfile -File scripts/measure-kotlin.ps1
& '<PINNED_PWSH>' -NoProfile -File scripts/measure-kotlin.ps1 -Offline
# JAVA_HOME / PATH 不指向所需 JDK 时：
& '<PINNED_PWSH>' -NoProfile -File scripts/measure-kotlin.ps1 -Offline -JavaPath '<JDK_HOME>/bin/java.exe'
```

首次从 Maven Central 下载 `tool-lock.json` 钉定的 detekt 1.23.8 独立 JAR；
下载后和每次执行前都验证已提交的 SHA256。缓存不存在时 `-Offline` 直接失败；
缓存校验失败时拒绝执行，不自动覆盖可疑文件。缓存与报告都在已忽略的
`.checks/kotlin-metrics/`，不改生产源码，不接入 Gradle，不改变 strict dependency verification。

这个入口用于量化和选择重构目标，未设置质量阈值。它直接调用 detekt 自带的 Kotlin PSI
及官方 `LinesOfCode` / `CyclomaticComplexity` / `CognitiveComplexity` 实现，
没有格式化、自动修复或抑制基线；源码的 `@Suppress` 不会隐藏测量对象。
当前 JAR 内嵌 Kotlin 2.0.21，独立解析项目 Kotlin 2.0.20 源码；
Android 的 Kotlin / AGP 版本保持不变。这里不提供类型解析或语义编译验证，原有编译门仍须运行。

## 范围和指标口径

输入是 Git 已跟踪及未忽略的新增 `.kt` 工作树文件，包括 `app/`、`spikes/` 与测试。
忽略目录里的生成物不会进入测量；`.kts` 不在本报告范围内。
每个 `KtNamedFunction` 一行，包括局部函数、匿名 `fun`、重载和匿名对象的方法；
构造器、属性访问器及 lambda 不独立列为函数。重载用路径和起始行区分。

| 列 | 定义 |
| --- | --- |
| `path` / `sourceSet` | 仓库相对路径；`src/` 后的目录名，如 `main`、`debug`、`testDebug`，其余为 `other` |
| `startLine` / `endLine` | Kotlin PSI 确定的 `fun` 关键字到整个函数节点最后字符所在行，均从 1 开始 |
| `physicalLines` | `endLine - startLine + 1`；包含内部空行、注释、lambda 和局部函数，不含之前的 KDoc、注解或单独占行的修饰符 |
| `codeLines` | 官方 detekt `linesOfCode(function)`；计算整个函数节点非注释、非空白叶子 token 的不同起始行，包含前置注解和内部局部函数；多行字符串的文本不保证逐行计入 |
| `cyclomatic` / `cognitive` | 官方 detekt 默认配置在该函数 PSI 节点上的圈复杂度 / 认知复杂度；嵌套节点的归属按官方实现，不可把各行指标相加当作项目总量 |

`codeLines` **不是** detekt `LongMethod` 规则的值：该规则还会按函数体和嵌套函数做扣减。
不要把任何去注释、扣减或复杂度值称作物理行数。圈复杂度默认包含 `let` 等嵌套函数调用；
detekt 1.23.8 对匿名对象内部方法跳过该项计算，因此这些行的圈复杂度可以为 0。
排名是当前输入范围的函数排名，不覆盖 `.kts`、构造器或访问器。

## 输出和失败

| 文件 | 内容 |
| --- | --- |
| `summary.json` | 成功 / 失败状态、工具版本、分析器与输入 SHA256、文件与函数数量、全范围及 `main` 的长度前 20、`main` 的复杂度前 20 |
| `functions.csv` | 全部函数，按物理跨度降序，路径和起始行作为稳定次序 |
| `inputs.txt` / `input-hashes.csv` | 精确输入清单及各文件 SHA256；分析结束再次核验清单及内容，期间变化则失败 |
| `analysis.log` | Java / PSI 的完整运行输出 |

每次先运行内置人工预期的回归样例：字符串和注释中的花括号、字符串模板、原始多行字符串、
lambda、局部函数、表达式体、重载、匿名函数、BOM/CRLF 及语法错误。
任何 Kotlin 语法错误都会失败，避免把漏算结果发布为排名。
成功结果不含时间戳；相同输入、工具和脚本应产生相同报告。
`extractorSha256` 在启动 Java 前记录，执行后再次核验；分析器源码期间变化则失败。
失败后旧 CSV 可能仍存在，**只在 `summary.json` 的 `status` 为 `passed` 时使用排名**。
`run.lock` 是忽略目录内的独占文件锁，避免两次运行并发写同一份报告；进程结束自动释放锁。

工具实现与锁文件更新应一起审查，重新核验官方发布物 SHA256，并重跑内置回归及项目测量。

## 官方依据

- [detekt 1.23.8 CLI](https://detekt.dev/docs/1.23.8/gettingstarted/cli/)
- [detekt 兼容表](https://detekt.dev/docs/1.23.8/introduction/compatibility/)：1.23.8 内嵌 Kotlin 2.0.21，最高测试 JDK 21；表中的 Gradle / AGP 是插件构建组合，不是本工具升级生产依赖的要求。
- [Maven Central 发布 SHA256](https://repo.maven.apache.org/maven2/io/gitlab/arturbosch/detekt/detekt-cli/1.23.8/detekt-cli-1.23.8-all.jar.sha256)
- [固定版本指标源码](https://github.com/detekt/detekt/tree/v1.23.8/detekt-metrics/src/main/kotlin/io/github/detekt/metrics)
- [LongMethod 的独立口径](https://github.com/detekt/detekt/blob/v1.23.8/detekt-rules-complexity/src/main/kotlin/io/gitlab/arturbosch/detekt/rules/complexity/LongMethod.kt)
