# vivo / OriginOS（主力测试机：V2352A · X100 系列，Android 16，1260×2800）

> 来源：M0/M0.5 实测（2026-07-16/17）。原始记录：[../../runs/2026-07-16-M0.md](../../runs/2026-07-16-M0.md)。品牌开关完整矩阵见 [M0 runbook §1.1](../../runbooks/M0-runbook.md)。

## 调试与注入

- **「USB 模拟点击」开关必开**，否则注入报 SecurityException；开了之后 tap/swipe 完全正常（实测确认）。
- OriginOS 5 有 ADB 白名单：一直 unauthorized 就检查「USB 调试 → 仅允许指定计算机调试」。
- 保活：网关/探针类 App 需电池白名单 + 后台高耗电允许，防无障碍服务被静默回收。
- **开发期开无障碍服务免手动，但不持久**（S2/S3 实测，2026-07-17/18）：`adb shell settings put secure enabled_accessibility_services <pkg/svc>` + `settings put secure accessibility_enabled 1` 两键同置，OriginOS6 下**异步生效 ~3s**（同一命令内立即 `get` 读到空是正常，下次读即有），服务随即 `connected`。⚠️ 两个坑：① **`input tap` 点无障碍详情页的启用开关无效**（反自动化拦截），settings 路径可绕过；② **settings 路径开启的服务数小时后被系统撤销**（实测 22:22→01:24 之间两键被清+服务进程回收，疑似午夜/空闲策略）。开发期对策：**每次跑测前重放两条 put**（恢复即时）；持久启用需设置 UI 手动开 + 电池白名单 + 后台高耗电允许（真实用户场景 M2 必须走 UI 引导）。

## 深链 / Intent

- **系统设置深链不可靠**：`am start -a android.settings.BLUETOOTH_SETTINGS` 不把蓝牙页带到前台（主设置 intent 正常）。执行器 `open_uri` 必须有「深链失败 → UI 导航兜底」（M1a 已内建执行后验前台）。

## 输入法

- **vivo 默认联想输入法吞空格**（M0.5 复测实锤）：合成态把空格当「选词确认」——"harness drill 0717" 连成 "harnessdrill0717"，单发空格无效、全选重输同样复现。含空格文本无法精确录入。对策 = M1 自有 IME 字面注入；临时绕法：切无预测 ABC 键盘 / 任务文本避开空格。
- 输入法预测引擎会篡改大小写（M0 实测，微信任务误触诱因之一）。

## 待真机验证（Spike）

- Shizuku 重启存活性、无线调试重启后是否被关（S2；**激活本身已 S2 实测成功**——v13.6.0 经 `libshizuku.so` 起 `shizuku_server`；重启存活待手机重启后验）。
- 其余系统设置子页 intent 是否带到前台（无障碍页 `ACCESSIBILITY_SETTINGS` 已 ✅ 转正，WiFi/输入法/应用详情待验，见 [sys-cli.md §4](sys-cli.md)）。
