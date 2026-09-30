# C1b 当前候选主机证据链

此入口承接 [C1b 规程](T-L1-tablet-layout-c1b-v1.md)和[候选源码准备](T-L1-c1b-candidate-source.md)。
只消费本轮完整 SHA 的实际证据；合成测试、历史授权或旧合同不构成新候选通过。
已消费候选保留原始材料，不运行普通 Git、全量门、preflight 或 launcher 补证。

## 串行阶段

1. 完成实现与独审，小步提交；建立对象库独立的普通 clone，准备期完成 FullCheck 全量门及独立 Run/Read 捕获。
   最终冻结前再次核实完整 SHA、工作树和实际输入，不以分支名称推断版本。
2. `audit-c1b-candidate-authority.ps1` 在 preparation 状态核定 A1：实际 Git head/branch/status/tree 各自双流捕获，
   native exit 与 EOF/Job cleanup 分别记录；native-held Git metadata、index/tree 与 42 项 raw implementation catalog 对齐。
   调用方另捕获 auditor 自身进程及退出，A1 receipt 无法证明自身最终 native exit。
3. `invoke-c1b-candidate-host-stage.ps1` 继续运行 PrepareSources、Pair、R14、Preflight。
   每阶段绑定 caller-reviewed 状态、runtime、精确 argv/cwd、传输源码、环境和工件清单。Run 与独立 Read
   均须有额外外层 capture 和 root observation；调用方在 spawn 前持有实际 invoker 与其相邻 module/capture，
   闭合首次加载源码。Read 明确不声称观察到自身最后退出。
4. 对完整 SHA 和实际 launcher hash 记录当前有效用户授权。`invoke-c1b-build-only-elevated.ps1` 的 Drive
   以固定 candidate once marker 预约一次 RunAs；Elevated 再用独立 CreateNew marker 防止参数重放。
   实际提升进程核验管理员令牌、runtime、源码与通过的 preflight，再单次捕获 launcher 的 stdout/stderr。
   Drive 独立记录 RunAs Process 的 PID/native exit；它的 Job 不自动覆盖 UAC broker 创建的进程。
   提升启动或 launcher 失败也消费尝试，automatic retry=0。
5. `read-c1b-build-only-host.ps1` 作为 Readback 阶段，核定真实 launcher/driver capture、PID、原始流、摘要和日志。
   strict verifier/private FunctionInfo 从准确 held source bytes 载入；成功报告要求没有失败或 unknown。
   报告发布 exit 0 与 accepted_no_device 是两个不同事实，reader 的真实退出由其外层 capture 核验。
6. `seal-c1b-host-raw-evidence.ps1` 对精确 inventory 进行唯一 raw 封存：source/copy pins、ordinary parents、
   stable identity、single-link、原始长度/hash、只读副本和清理均核验；调用方捕获封存进程最后退出。
7. `write-c1b-host-acceptance.ps1` 消费 caller-pinned InputMap 和独立 source review，重读所有 A1、阶段、
   BuildOnly、Readback、封存事实，发布 `c1b-host-device-entry-acceptance/v1`。
   合同输入都是精确 path/byte_length/sha256；receipt、review 结论或 raw 副本本身不能替代进程证据。
8. `prepare-c1b-device-entry-source.ps1` 从版本控制维护源派生本候选入口，独审后发布；Binding、observer Prefix
   与 Ready 都绑定真实阶段退出和双流。Ready 重消费当前主机合同，不访问设备，不自行确认当前现场。
   Binding 在创建 attempt 目录前验证已核定 `context.implementation_hashes.runner_sha256` 是严格
   `sha256:` 加小写 64 位十六进制字符串，再将裸 hash 写入顶层 `runner_sha256`，供 R3 核对当前 runner。
   正式 R3 reader/freezer 从真实终态与 stdout 内容指针取 internal attempt/run identity；缺失事实保持 unknown，
   不按 mtime 扫描猜测，失败封存不自动重试。

## 保留的边界

运行时文件、绝对路径、日志和状态材料放在忽略的证据目录；tracked 文档保留相对指针与原始 hash。
repo、工具根和 evidence roots 必须由调用方明确核定，不能从任意 leaf pins 自动扩大信任范围。
新候选尚未完成这些实际阶段时，不能发布 Ready。进入真机阶段仍核对本轮唯一设备、横屏应用多窗、IME 和
用户现场确认；发送、支付、删除等操作保留手机可见临界确认。
