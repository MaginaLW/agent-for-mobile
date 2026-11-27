# 系统状态只读核对（L1 API-first）

只读查询本机蓝牙、Wi-Fi、电量与网络状态，在「关键观察」逐项报告数值与真值源（`source`）。严禁修改任何系统开关或进入系统设置 UI。

- 首步直接调用 `skill_macro_exec(name="settings_state_readonly_check", params={"key": "bluetooth"})` 查询蓝牙状态，并可继续使用同一宏（或直接 `system_get_state`）依次查询 `wifi`、`battery`、`network`；读取 `data.status` 与 `data.final_snapshot`（含 `value` 与 `source`）。
- **禁止进入设置 UI**：不要调用 `app_launch(name="设置")` 或 `open_uri` 打开系统设置页（避免安全中心在设置前台撤销第三方无障碍；且 OriginOS 上 `BLUETOOTH_SETTINGS` 直达不可靠）。
- 若返回 `E_PERM_MISSING`（如缺 `BLUETOOTH_CONNECT`）或任何安全终态错误，立即按站规停下如实报告失败与缺失权限，禁止重试或绕过。
