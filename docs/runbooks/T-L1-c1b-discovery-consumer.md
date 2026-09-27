# C1b 设备发现证据读回与封存

`scripts/read-tablet-layout-c1b-discovery-evidence.ps1` 是离线只读消费入口。它按本轮
`attempt_id`、完整代码 SHA 和已观察到的终态，读取 `docs/runs/evidence/` 根目录的
`before_install`、`after_capture` 两份发现记录及可能存在的无 run ID 早期失败记录。
它不会运行 ADB、构建、安装或采集，也不把记录本身判为设备验收通过。

用钉定 PowerShell 调用 `-Mode Read`；只有运行已产生 run ID 时才提供 `-RunId`。
早期失败的 `run_id=null` 不应传入旧 Ready 或猜测的 run ID。缺席检查点默认为
`absent_unknown`；已核实的无 run ID 失败才把两个检查点记为 `not_reached`。

```powershell
& '<repos-root>/_toolchain/powershell-7.6.5/pwsh.exe' -NoProfile -File `
  scripts/read-tablet-layout-c1b-discovery-evidence.ps1 -Mode Read `
  -AttemptId '<本轮 attempt ID>' -ExpectedCommitSha '<40 位 SHA>' `
  -TerminalStatus failed
```

`-Mode Freeze` 复用相同的读回合同，另需 `-DestinationDirectory` 指向**本仓库 `.checks/`
下已存在且为空**的本轮独占目录。它只复制已出现的原始记录并写入
`freeze-manifest.json`；若任何读回、hash、复制或落盘失败，不发布成功 manifest。
封存目录及其原始记录和失败日志保留，不能拿旧轮 manifest 补造本轮缺席证据。

离线反例入口为 `scripts/tests/tablet-layout-c1b-discovery-consumer-offline.ps1`。
Read/Freeze 通过只是 A5 消费工具就绪的证据；新候选还须依本轮协调来源的
`docs/backlog.md` 完成固定 SHA、主机阶段、独立读回和本轮设备条件。
