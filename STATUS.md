# 项目状态

> 每次会话收尾更新。保持 ≤ 20 行。

- **当前阶段**：**M1 真机日已执行（2026-07-17～18，[结论](docs/runs/2026-07-17-M1-spike.md)）**。Spike 定论：**S1 微信树 ❌ 不可读**（自研 a11y flag 拉满仍 root=null，列表/会话/键盘三态一致）→ **OCR 融合拍板提前进 M1a**；S2 `svc`/`cmd` 蓝牙/WiFi 双通道均生效 + Shizuku v13.6.0 激活；S3 OCR 达标（~450ms，中文控件 conf 0.6–0.9，深色/京东重页不塌方）；S4 截图 32–37ms、连发软节流（非硬失败）；S5 ShareImgUI 有效。**网关 M1a bring-up 成功**：22 工具面 L1/L2/L4/L6 零 token smoke 全绿，首跑修 2 真 bug（MainActivity 直读 ENABLED_INPUT_METHODS 崩溃、缺 ACCESS_WIFI_STATE），**中文输入链闭环一次通过**（a11y_set_text readback 与输入完全一致）。本地构建链就位（D:\android：JDK17+Gradle8.11.1+SDK35）。
- **下一步（按序）**：
  1. **大脑端到端联调**（任务 1 关蓝牙 UI 兜底链 / 任务 4 media_query+share_file）：`configs/gateway-mcp.json` 填 token → `claude --mcp-config configs/gateway-mcp.json`；手工记台账 note=executor:gateway → 回填 spec §12 定量成本。**涉危险动作两段式，用户主导**；⚠️ confirm 悬浮窗在 vivo 后台被拦（[vivo册](docs/knowledge/android/vivo-originos.md)），危险动作走带外 `[AWAIT_CONFIRM]`——通道去险 3 项已补验（ui_action/confirm/share_file）。
  2. 遗留补测：S5 RemoteInput（需外部设备发微信消息后 dump）；S2 Shizuku 重启存活（需重启手机 + 解锁）；`open_uri` 小红书深链复核（本次 verify fail，疑深链失效或冷启 >3s）。
  3. 两段式第二腿收口（`scripts/dispatch.ps1 -Confirm`，人工键入 CONFIRM）。
- **知识归档**（真机日回填）：sys-cli.md（蓝牙真值源改文本 / svc·cmd 双生效 / Shizuku 激活法 / ACCESSIBILITY_SETTINGS 转正）、common.md（S4 软节流窗口）、vivo-originos.md（settings put 开无障碍 + input tap 无效）、wechat.md（S1 三态不可读 + 键盘感知 + ShareImgUI）、apps.json 同步。
- **障碍**：无。顺手：微信文件传输助手旧草稿 "harness" 仍在。
