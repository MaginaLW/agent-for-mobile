# C1b `14edb4a` BuildOnly 管理员令牌失败

## 固定输入与授权

- 候选 SHA：`14edb4a477ddd71c82f029008c0772e485d682bf`；A1—A3 和只读 preflight 的证据见 [主机准备](2026-09-29-C1b-14edb4a-A1-A3主机准备.md)。
- 用户在收到绑定本 SHA、launcher SHA-256 `1637e8b43c2ebf69f81028eb0a037cfa3293dbbe9e543abcdf78f7f55782daaa`、BuildOnly 范围及自动重试 0 的询问后，回复“继续下一步”。本轮据此只调用 launcher 一次，并显式传入 mandatory `-ExpectedLauncherSha256`。
- 调用前重新读回 launcher 和 preflight 回执 hash，确认预检外层 exit `0`、模块 build 与 smoke 输出缺席、PC Suite/ADB 进程及 TCP/5037 监听均为 0。

## 单次结果

launcher 进入 `elevation_check` 后发现 `elevated_token=false`，外层实际 exit `1`。
原始外层日志 `.checks/c1b-candidate-a4/build-only-once.outer.log` SHA-256
`d89399203489706b4ac992089a69d2adc0973940e09b8cbcd72d509aff9e9434`，同目录退出码文件值为 `1`。
failure-only sidecar SHA-256 为
`75a8c3e61608823e2a7e11a60cad85516611ac3aa1018ad49850e642e9758c8b`；其闭合字段记录
`phase=elevation_check`、helper start attempt/count 均为 `0`、automatic retry `0`、
`success_eligible=false`。summary、构建日志、launcher result、模块 build 均不存在；失败后检查时
ADB 进程与 TCP/5037 监听均为 0。没有 helper、Gradle、ADB、安装或采集执行证据。

该 SHA 的单次 BuildOnly 尝试已消耗并封存，不以提升权限为由在同一候选重跑。
下一候选须在冻结及询问单次授权前核对实际 launcher 令牌可提升并准备可审计的提升启动方式；
只读 preflight 的通过不能替代这一主机条件。新 SHA 须重走 A1—A3，并获得新的 BuildOnly 单次授权。

PC Suite 曾为满足本轮预检而把“关闭主面板”临时改为“退出应用”；本次失败后已重新启动应用，
但桌面界面控制未能取得稳定窗口，原“最小化到任务栏”设置仍待恢复。
