# 项目状态

> 每次会话收尾更新。保持 ≤ 20 行。

- **当前阶段**：**M1b OCR 融合层落地并真机验收通过（2026-07-19，[记录](docs/runs/2026-07-19-M1b-OCR融合.md)）**。`ui_snapshot` 树空/稀疏自动融合 OCR（source=a11y|ocr|fused，revision+2s TTL 缓存，手势后失效）；OCR ref 点击前裁剪重识二次校验 + dispatchGesture；无列表页手势滚动兜底；`type_text` 修「SET_TEXT 假成功不触发 IME 降级」+ OCR 读回闭环；`wait_for` 文本条件接 OCR 感知面。**微信选择页全链真机走通**（snapshot 17 OCR 元素 → find → 校验点击 → 发送确认弹窗读出 → 取消，零副作用；聊天列表页 31 元素含「文件传输助手」）。真机 smoke 抓修 4 真 bug（fg 归属窗口化 / 悬浮节点误吞 OCR 行 / CJK 形近抖动 / SET_TEXT 假成功）。APK 59MB（ML Kit bundled +48MB）。
- **下一步（按序）**：
  1. **Shizuku 接入**：`system_set_state` 直写（任务 1 成本回 <$0.1 口径）；顺带 `am start` 通道解**新实锤**——网关后台启动三方 app 被 vivo/Android16 BAL 拦（`share_file`/`app_launch(微信)` 不落前台，系统 app 放行，shell 可绕）。
  2. **IME 自动切换**（`pm grant WRITE_SECURE_SETTINGS`）+ type_text IME+OCR 读回腿真机闭环（代码就绪，本次未点上）。
  3. **任务 4/2 大脑端到端重跑**（融合层已解卡点）：文件传输助手不保证选择页首屏 → find 短子串「文件传输」+scroll_search 或搜索框通道。
  4. 遗留补测：S5 RemoteInput；S2 Shizuku 重启存活；`dispatch.ps1 -Confirm` 收口；share_file verify 收紧 activity 级。
- **障碍/观察**：微信深色模式灰字占位符（搜索/留言）OCR 漏识 ~40%（2s TTL 重识缓解，锚点避开）；vivo `install -r` 重置运行时权限 + a11y 需 toggle 重绑（bring-up 固定链见 vivo 册）；confirm 后台弹窗仍待 vivo「后台弹出界面」授权。
