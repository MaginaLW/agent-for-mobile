# vivo / OriginOS（主力测试机：V2352A · X100 系列，Android 16，1260×2800）

> 来源：M0/M0.5 实测（2026-07-16/17）。原始记录：[../../runs/2026-07-16-M0.md](../../runs/2026-07-16-M0.md)。品牌开关完整矩阵见 [M0 runbook §1.1](../../runbooks/M0-runbook.md)。

## 调试与注入

- **「USB 模拟点击」开关必开**，否则注入报 SecurityException；开了之后 tap/swipe 完全正常（实测确认）。
- OriginOS 5 有 ADB 白名单：一直 unauthorized 就检查「USB 调试 → 仅允许指定计算机调试」。
- 保活：网关/探针类 App 需电池白名单 + 后台高耗电允许，防无障碍服务被静默回收。

## 深链 / Intent

- **系统设置深链不可靠**：`am start -a android.settings.BLUETOOTH_SETTINGS` 不把蓝牙页带到前台（主设置 intent 正常）。执行器 `open_uri` 必须有「深链失败 → UI 导航兜底」（M1a 已内建执行后验前台）。

## 输入法

- **vivo 默认联想输入法吞空格**（M0.5 复测实锤）：合成态把空格当「选词确认」——"harness drill 0717" 连成 "harnessdrill0717"，单发空格无效、全选重输同样复现。含空格文本无法精确录入。对策 = M1 自有 IME 字面注入；临时绕法：切无预测 ABC 键盘 / 任务文本避开空格。
- 输入法预测引擎会篡改大小写（M0 实测，微信任务误触诱因之一）。

## 待真机验证（Spike）

- Shizuku 重启存活性、无线调试重启后是否被关（S2）。
- 各系统设置子页 intent 是否带到前台（[sys-cli.md §4](sys-cli.md) 🔵 清单）。
