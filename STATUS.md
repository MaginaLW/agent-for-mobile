# 项目状态

> 每次会话收尾更新。保持 ≤ 20 行。

- **当前阶段**：P0 统一硬门尚未整体通过。2026-07-24 真机验证了 9 轮：`conversationTitle`/`P0FocusProbeValidator` 两处识别级阈值不一致已修（knowledge #15/#16），`Start-P0TargetApp` 无条件重启微信的脚本 bug 已修（不再冲掉人工预置的会话页/焦点）。真机上确认这些修复让宏能稳定推进到更靠后的阶段，但仍卡在 `focus_probe_validation`（空白输入框无 ref）。**用只读 `screen_capture` 视觉核对排除了"截图缓存陈旧"的疑虑**——截图管线本身正确，标题/输入框都在；根因定位到比两处代码门槛更底层的 `OcrEngine.MIN_CONF=0.5`（[OcrEngine.kt](app/gateway/src/main/java/dev/magina/gateway/a11y/OcrEngine.kt)）——置信度低于此的文字连候选池都进不了，本次改的两处门槛（0.45/0.65）再低也够不着；这和 STATUS 里早已记录的"深色模式灰底灰字漏识约 40%"是同一个已知未解风险，详见 knowledge #16。
- **本次修订**：`conversationTitle()`、`P0FocusProbeValidator` 标题识别改用 `MIN_RECOGNITION_OCR_CONFIDENCE=0.45`（后者是真正的设计取舍，经用户拍板）；`scripts/lib/p0-device-provision.ps1` 的 `Start-P0TargetApp` 加前台检测，微信已在前台时不再无条件 `am start`；[`OcrEngine.recognize()`](app/gateway/src/main/java/dev/magina/gateway/ocr/OcrEngine.kt) 改为原图+灰度对比度拉伸图各识别一遍、按区域取置信度更高者合并，直接针对"深色模式灰底灰字漏识"根因（而非再调阈值）。全部改动已跑 Debug 171 + Release 93 = 264 tests 全绿、`assembleDebug` 成功；但 `OcrEngine` 本身全仓库零单测（依赖真实 Bitmap/ML Kit，本项目未配 Robolectric），对比度增强这次改动**尚未真机验证效果**，需要重新连接设备实测。
- **监督式 runner**：已离线实现且真机验证 provision/sensitive_entry/unrecognized_entry 均可正确通过；业务动作仍只走 `dispatch.ps1 → gateway MCP → SafetyGate → executor`。Allow/Stale 因 OCR 漏识仍未真正跑到确认卡这一步。
- **下一步（按序）**：
  1. 重新连接真机，用 `run-p0-safety-smoke.ps1 -Legs Allow,Stale -Executor gateway -Provision` 验证对比度增强是否解决了「文件传输助手」标题/输入框识别问题；若仍不够，可加感知阶段（点击前）的有限次数重试，或回头试强制浅色模式。
  2. 验证通过后两腿真实证据过了再把 P0 整体判过；随后处理 D3 OCR 输入读回、Shizuku、IME 自动切换及任务 4/2 端到端链路。
- **遗留/障碍**：真实 Allow/Stale 尚未触发确认卡（OCR 漏识阻断，见上，对比度增强修复待真机验证）；Deny 确认卡截图沿用既有证据缺口；`app/gradlew` 等 wrapper 文件已由用户自行提交入库；S5 RemoteInput、S2 Shizuku 重启存活、`dispatch.ps1 -Confirm` 收口、`share_file` activity 级 verify 待补；Codex 订阅额度已耗尽（2026-07-30 恢复，现已非构建阻塞项）。
