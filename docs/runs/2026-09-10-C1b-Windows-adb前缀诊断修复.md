# C1b Windows adb 前缀诊断修复

`d11e22e/r1` 实际安装失败，但安全摘要未带系统错误码；原始安装器正文未保留。
用户另外报告误点平板安装/授权提示并要求重推。两者见
[r1 真机记录](2026-09-10-C1b-d11e22e-r1-真机验证.md)，不能相互替代或按输出长度反推错误码。

## 源码证明的缺口与修复

AOSP 的 streamed install 通过 `error_exit` 输出安装失败；错误函数使用实际可执行文件 basename 作为前缀，
Windows 的可执行路径保留 `.exe` 扩展名。因此官方 Windows ADB 能产生 `adb.exe: failed to install ...`。
来源：[安装输出](https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/client/adb_install.cpp)、
[错误前缀](https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/android15-qpr2-s8-release/client/adb_client.cpp)、
[Windows 可执行路径](https://android.googlesource.com/platform/system/libbase/+/refs/heads/main/file.cpp)。

原分类器只接受 `adb:`，会把上述 Windows 形态保守拒绝为 null。stdout 的 streamed install 提示已有覆盖，
真实 operation/client-kind 接线正常；本轮确定的缺口是错误前缀兼容性。
这不能证明已丢失的 r1 正文就是该形态，也不能确认其具体系统错误码。

开发目录只将可选程序名前缀改为 `adb(?:\.exe)?:`，保留固定27码允许列表、唯一 `INSTALL_` token、
完整失败行、严格 UTF-8、完整双流、无溢出及非安装错误拒绝规则。不改 ADB 参数、安装动作、失败门或重试策略，
不输出正文、设备/主机路径或内容 hash。

新增三条真实 fake-client 链：Windows 前缀阳性，`adbxexe` 与 `adb.exe.bad` 阴性；
直接分类表同时拒绝 `prefixadb.exe`。阳性断言安全 Message 保留固定码，Message/Data/ToString 不泄露 canary。
聚合门的专项期望数量从37同步为40。独立代码审核通过；反向恢复注释和正则后，
仅归一换行的库全文与冻结 `d11e22e` 完全一致，证明改动限于诊断。

## 验证与候选边界

固定 PowerShell 7.6.5 专项实际子进程 exit 0，UTC `23:42:56.0514767 → 23:43:18.2768914`，
40 passed / 0 failed，双流 EOF 完整、stderr 0 字节、cleanup 完成，真实 ADB/JDK/Gradle 均未执行。
原始材料位于开发目录 `.checks/c1b-install-code-windows-prefix/specialized/`。

C1b host 聚合消费者实际子进程 exit 0，UTC `23:43:25.517 → 23:50:26.441`，
29/29，双流 EOF 完整、stderr 0 字节、cleanup 完成，真实 ADB 调用为0。
该目录 `verification.json`（4096字节，SHA-256
`804cfe77b5cfc5fe04d926e75a1336326695c338174beeeacc234dda47806f2b`）记录源码与原始验证材料；
14份本地产物只读保存，其中13份被引用文件已独立回读核对。
辅助封存脚本首轮因 PowerShell 保留变量在输出前失败，修正后封存完成，未重跑上述测试。

修复只在开发目录；已冻结 `d11e22e` 及按用户要求准备的同 SHA r2 不包含该修复。
本次重推沿用已验证候选，若仍安装失败，其 Windows 前缀错误码可能继续为 null；
后续应用诊断修复需另建固定候选及其必要门，不能通过改写旧候选或复用新代码名义绕过。
