# 项目状态

> 每次会话收尾更新。保持 ≤ 20 行。

- **当前阶段**：**M1a 真机验收基本达成（2026-07-17～18，[结论](docs/runs/2026-07-17-M1-spike.md)）**。Spike：S1 微信树 ❌ 不可读 → OCR 融合进 M1a；S2 `svc`/`cmd` 双通道生效 + Shizuku 激活；S3 OCR 达标 ~450ms；S4 截图软节流；S5 ShareImgUI 有效。**网关 bring-up + 大脑端到端联调**：22 工具面 smoke 全绿；**任务 1（关蓝牙 UI 兜底链）12 轮/$0.37/零 screen_capture 端到端打通——摆脱 PC-adb 截图链路**；任务 4（发图文传助手）⚠️ blocked 于微信选择页不可读（缺 OCR）。首跑共抓修 **3 个真 bug**：IME 直读崩溃、缺 ACCESS_WIFI_STATE、**ui_action 对 Switch 节点 a11y-click 无效 → dispatchGesture 坐标点击**。中文输入链闭环通过。本地构建链就位（D:\android）。
- **下一步（按序）**：
  1. **M1b OCR 融合层**（S1 定 + 任务 4 blocked 双重硬要求）：解微信选人/读消息，任务 2/4 通道打通。
  2. **Shizuku 接入**：`system_set_state` 直写省任务 1 的 UI 兜底（成本回 §12 <$0.1 口径）。
  3. 遗留补测：S5 RemoteInput（外部发消息）；S2 Shizuku 重启存活（重启+解锁）；两段式第二腿收口（`dispatch.ps1 -Confirm`）。
- **障碍/观察**：confirm 悬浮窗在 vivo 后台被拦（[vivo册](docs/knowledge/android/vivo-originos.md)），危险动作走带外 `[AWAIT_CONFIRM]`；share_file 拉起微信选择页稳定性依赖进程状态，verify 宜收紧到 activity 级。代码改动（Gateway.kt / Manifest / GatewayA11yService.kt）未提交。
