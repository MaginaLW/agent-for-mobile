# M1 Spike 周 Runbook（S1–S5 去险实验）

> 前置：[M1 执行网关设计](../specs/2026-07-17-M1执行网关-design.md) 已批准（2026-07-17）。本 runbook 是其 §11 Spike 清单的可执行版。每项 ≤ 半天；**S1 优先**（决定 OCR 融合层是否进 M1a、成本估算上下限）。
> 设备：vivo V2352A（Android 16 / OriginOS，1260×2800），USB 调试 + 「USB 模拟点击」已开（见 [devices.md](../knowledge/devices.md)）。
> 结果记录：跑完写 `docs/runs/2026-07-XX-M1-spike.md`，实锤结论按册归入 knowledge/，并回填 spec §11/§12 的估算。

## 0. 探针 App 构建（S1/S3/S4 共用，一次性）

工程在 `spikes/probe/`（**云端产出，未编译过**——首次构建报错属预期内，小修即可）：

```powershell
# 推荐：Android Studio 打开 spikes/probe/，同步后 Run（Studio 会自动补 gradle wrapper）
# 或命令行（本机装有 gradle 8.7+ 与 Android SDK 35）：
cd spikes/probe
gradle :app:assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

装完三步：① 点开 a11y-probe 一次（部分 ROM 对从未启动的 app 隐藏无障碍入口）；② 设置 → 无障碍 → 开启「a11y-probe」（vivo 路径：设置→快捷与辅助→无障碍）；③ `adb logcat -s a11yprobe` 应看到 `probe connected`。

探针命令面（结果落 `/sdcard/Android/data/dev.magina.a11yprobe/files/`）：

```powershell
adb shell am broadcast -a probe.DUMP   # 当前所有交互窗口节点树 → dump-*.txt
adb shell am broadcast -a probe.SHOT   # takeScreenshot 计时 + ML Kit 中文 OCR 计时 → shot-*.png / ocr-*.txt
adb pull /sdcard/Android/data/dev.magina.a11yprobe/files/ docs/runs/traces/spike/
```

## S1 ⭐ 微信节点树可读性（半天，最高优先）

**问题**：M0「微信树恒空」结论绑定在 uiautomator 通道上；自研 a11y 服务（flagIncludeNotImportantViews + flagRetrieveInteractiveWindows 拉满）可能读得到。

1. 打开微信 → 停在**聊天列表页** → `probe.DUMP`。
2. 进「文件传输助手」**会话页** → `probe.DUMP`。
3. 点输入框弹出键盘 → `probe.DUMP`（顺带看 IME 窗口是否出现在 windows 列表——键盘感知通道的验证）。
4. 对照组：同页面跑 `adb shell uiautomator dump` 各一次（预期空/极稀疏）。

**判据**（看 dump 文件尾部 `nodes= / withText=`）：
- ✅ 可读：会话页能看到消息文本、输入框（E 标记）、「发送」等节点 → **OCR 融合层推迟到 M1b，任务 2/4 成本估算取下限**。
- ⚠️ 半可读：有节点骨架但文本缺失 → 融合层进 M1a，OCR 只补文本。
- ❌ 不可读：与 uiautomator 一样空 → 融合层进 M1a 且为微信类任务主通道，spec §12 估算上浮 ~50%。

## S2 Shizuku 激活与系统开关命令（半天）

**先测命令有效性（不需要 Shizuku——adb shell 本身就是 shell uid，结论等价）**：

```powershell
adb shell svc bluetooth disable && adb shell dumpsys bluetooth_manager | findstr /i "state"
adb shell cmd bluetooth_manager disable   # Android 13+ svc 可能已弱化，两条都试
adb shell svc wifi disable && adb shell dumpsys wifi | findstr /i "Wi-Fi is"
# 测完恢复：svc bluetooth enable / svc wifi enable
```

记录哪条在 Android 16 真实生效（判据用 dumpsys 真值，不信 settings 键——M0 发现 #2）。

**再测 Shizuku 本体**：装 [Shizuku](https://shizuku.rikka.app/) APK → 经 adb 激活（`adb shell sh /sdcard/Android/data/moe.shizuku.privileged.api/start.sh`）→ 验证内置终端能跑上面生效的那条命令。**存活测试**：重启手机，记录 Shizuku 是否失活、无线调试是否被 OriginOS 关闭（决定 M2 前的专项工作量；M1 期 PC adb 在场，失活可随手重激活）。

## S3 ML Kit bundled 中文 OCR 精度/延迟（与 S4 同跑，半天）

在四种页面各 `probe.SHOT` 一次：微信聊天列表、微信会话页（含中文消息气泡）、京东首页（重动画）、深色模式任一页。

**判据**（看 ocr-*.txt）：
- 延迟：`ocr=` 毫秒数。≤500ms 可接受（融合是本地操作，不占模型轮次）；>1.5s 要考虑降分辨率或 PaddleOCR。
- 精度：中文文本行召回目测 ≥90%、关键控件文字（「发送」「文件传输助手」）必须命中且 bbox 准确；深色模式不塌方。
- 未达标 → 启用备选 PaddleOCR mobile（spec §9 升级位）。

## S4 takeScreenshot 延迟与节流（与 S3 同跑）

- 单发：看 logcat `takeScreenshot=` 毫秒数（判据 ≤500ms）。
- 节流：连发两次 `probe.SHOT`（间隔 <1s），第二次预期 `SHOT failed`（ERROR_TAKE_SCREENSHOT_INTERVAL_TIME_SHORT）；再测间隔 1s/2s 找出实际冷却窗口，写进 knowledge/devices.md（网关 `E_RATE_LIMITED` 的冷却值就用它）。

## S5 微信通知 RemoteInput 与 ShareImgUI 直达组件（半天）

**RemoteInput**（预期阴性，实证即可）：另一设备给测试机微信发消息 → 通知还在时：

```powershell
adb shell dumpsys notification --noredact > notif.txt   # 找 com.tencent.mm 段
# 看 actions 里有无 RemoteInput / 「回复」快捷动作
```

**ShareImgUI**：先手动走一次系统分享（相册选图 → 分享 → 微信）确认现版本组件名：

```powershell
adb shell dumpsys activity activities | findstr /i "tencent.mm"   # 分享面板停留时抓
# 再尝试直达（media id 用 content query 取最新截图）：
adb shell content query --uri content://media/external/images/media --projection _id --sort "date_added DESC" # 取首行 id
adb shell am start -n com.tencent.mm/.ui.tools.ShareImgUI -a android.intent.action.SEND -t "image/*" --eu android.intent.extra.STREAM content://media/external/images/media/<id> --grant-read-uri-permission
```

⚠️ shell 侧 URI 授权可能被 MediaProvider 拒（FileProvider 语境才完整）——shell 测到「组件存在且能拉起」即算通过，URI 投喂的最终验证放 M1a 代码里做。

**判据**：RemoteInput 有/无（有则 notification_reply 对微信可用，超预期收益）；ShareImgUI 组件名确认（决定任务 4 走直达还是系统分享面板）。

## 收尾清单

1. `docs/runs/2026-07-XX-M1-spike.md`：五项结论 + 数据（延迟毫秒、节点数、OCR 行数）。
2. knowledge 归档：S1→apps.md 微信节；S2/S4→devices.md；S5→apps.md + deeplinks.md（ShareImgUI 按深链入库规程记设备与日期）。
3. 回填 spec：§11 的「OCR 融合是否进 M1a」拍板；§12 估算按 S1 结果修正。
4. 更新 STATUS.md，M1a 动工。
