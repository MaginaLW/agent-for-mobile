# 实测深链库

> 深链按 app 逐个实测建库（M0 结论：系统 intent 反而不可靠，app 自定义 scheme 更稳）。这份库是将来 App 技能包的原料——每条命中都省掉多步导航+中文输入的真金白银。

| App / 系统 | 深链 | 效果 | 实测（设备/日期） |
|---|---|---|---|
| 小红书 | `xhsdiscover://search/result?keyword=<urlencoded>` | ✅ 一步直达搜索结果页 | vivo V2352A / 2026-07-16 |
| 系统设置 | `am start -a android.settings.BLUETOOTH_SETTINGS` | ❌ OriginOS 上不把蓝牙页带到前台 | vivo V2352A / 2026-07-16 |
| 系统设置 | 主设置 intent（`android.settings.SETTINGS`） | ✅ 正常 | vivo V2352A / 2026-07-16 |

## 使用原则

- 深链失败必须有 UI 导航兜底（执行器 `open_link` 的内建逻辑）。
- 新深链入库前先在目标设备实测，注明设备与日期。
- 待建：微信、京东、淘宝、支付宝的常用 scheme 清单（M1 期间随任务积累）。
