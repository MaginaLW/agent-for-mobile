# M0 Runbook：零代码概念验证

> ⚠️ **2026-07-16 harness 重组后**：mobile server 不再常驻项目 `.mcp.json`（开发会话不挂手机工具）。复跑本 runbook 时，所有 `claude` 命令加 `--mcp-config configs/mobile-mcp.json`（在仓库根运行）。背景见 [brain/harness.md](../knowledge/brain/harness.md)。

目标：用 Claude Code + mobile-mcp + adb 操控真机跑完 5 个验收任务，产出**成功率**和**每任务 token 消耗**两组硬数据。
预计耗时：手机准备 15 分钟 + 每任务 5–15 分钟。

## 0. PC 侧环境（✅ 已就绪，2026-07-16 由 Claude 完成）

| 项 | 状态 |
|---|---|
| Node 24.16 / npm 11.13（满足 mobile-mcp 要求 Node ≥ 20） | ✅ 已有 |
| Claude Code 2.1.206 / Codex CLI 0.144.2 | ✅ 已有 |
| adb 37.0.1（`winget install Google.PlatformTools`） | ✅ 已装 |
| scrcpy 4.0（测试时镜像手机屏幕，`winget install Genymobile.scrcpy`） | ✅ 已装 |
| mobile server 配置 [configs/mobile-mcp.json](../../configs/mobile-mcp.json)（官方 npx 写法，版本锁定 0.0.62 保证测试数据可比；原在项目 .mcp.json，2026-07-16 起按需挂载） | ✅ 已写 |
| ~~settings.json 预批准 `mcp__mobile`~~（已随 2026-07-16 harness 重组移除；交互会话首次调用批准一次，headless 用 `--allowedTools "mcp__mobile"`） | ⚠️ 已变更 |
| npx 包缓存预热（`@mobilenext/mobile-mcp@0.0.62`） | ✅ 已做 |
| `.mcp.json` 直接 npx 写法在本机实测可连（server 已在 Claude 会话里成功启动过） | ✅ 已验证 |

> 注意：adb/scrcpy 是本次新装的，**已打开的终端窗口要重开**才能拿到新 PATH。

## 1. 手机准备（唯一需要人手的部分）

1. **开发者选项**：设置 → 关于手机 → 连点「版本号」7 次。
2. **USB 调试**：开发者选项 → 打开「USB 调试」。品牌特定的额外开关见 §1.1。
3. USB 线连 PC → 手机弹窗「允许 USB 调试吗」→ 勾选「始终允许」→ 允许。
4. PC 上验证：
   ```powershell
   adb devices        # 应显示 <序列号>  device（不是 unauthorized/offline）
   ```
5. **装 devicekit APK（中文输入的硬前置！）**：mobile-mcp 默认只能输 ASCII；装上它官方的 devicekit 后，检测到中文会自动改走「写剪贴板 + 注入粘贴键」通道。
   ```powershell
   # 1.2.4 为 2026-07-13 发布的最新版；更新版本看 https://github.com/mobile-next/devicekit-android/releases
   curl.exe -L -o devicekit.apk https://github.com/mobile-next/devicekit-android/releases/download/1.2.4/devicekit.apk
   adb install -r devicekit.apk
   ```
6. 确认手机上微信、小红书、京东/淘宝已登录。
7. **防熄屏**：开发者选项 → 打开「充电时屏幕不休眠」（Stay awake，USB 插着即生效）；再临时把锁屏方式改为「无」——整套测试要一小时以上，中途黑屏 agent 会卡住。

### 1.1 品牌特定开关（不开会导致「能读屏但点不动」）

| 品牌 | 额外要求 |
|---|---|
| 小米 HyperOS/MIUI | **必须**再开「USB 调试（安全设置）」（否则模拟点击报 SecurityException）和「USB 安装」；开启时要求插 SIM 卡 + 登录小米账号——可临时插任意 SIM 开完再拔，设置保持有效。HyperOS 2 开发者选项入口：我的设备 → 全部参数 → 连点 OS 版本 5 次 |
| vivo OriginOS | 再开「USB 模拟点击」；OriginOS 5 有 ADB 白名单，一直 unauthorized 就检查「USB 调试 → 仅允许指定计算机调试」 |
| OPPO ColorOS | 开「禁止权限监控」（ColorOS 16 默认隐藏，可切英文语言后找 Disable system optimization）；对纯点按影响较小 |
| 荣耀 MagicOS | 常规开启即可；注意给相关进程放开后台省电限制 |
| 三星 One UI | 最省事，常规流程，无额外开关 |
| 华为鸿蒙 NEXT | ❌ **不支持标准 adb**（只有华为自家 hdc），不能用于 M0——请换其他安卓机 |

开完后验证模拟点击没被系统拦截：
```powershell
adb shell input tap 500 500    # 若报 SecurityException/INJECT_EVENTS 就是品牌开关没开全
```

**备选：无线调试**（Android 11+，不想插线时用；截图传输比 USB 慢，M0 优先 USB）：手机「无线调试 → 使用配对码配对设备」→ PC 上 `adb pair <IP>:<配对端口>`（输 6 位配对码）→ `adb connect <IP>:<连接端口>`。注意配对端口≠连接端口，息屏/切网后端口会变。

## 2. 冒烟测试（5 分钟）

```powershell
# —— 终端 A：镜像观察窗（全程开着）——
adb devices                  # 先确认显示 <序列号> device
scrcpy --no-control          # --no-control = 只看不控，防止误点镜像窗把触摸注进手机干扰 agent

# —— 终端 B：跑 agent ——
cd D:\repos\agent-for-mobile
claude --mcp-config configs/mobile-mcp.json   # 首次工具调用批准一次（或加 --allowedTools "mcp__mobile"）
```
会话内：
- `/mcp` → 应看到 `mobile` server 已连接及其工具列表。
- 冒烟提示词：`用 mobile 工具列出手机上已安装的应用，然后截一张当前屏幕给我看。`

若失败，跳 §6 排错。

## 3. 正式测试流程（每任务标准化，保证数据可比）

每个任务固定五步：
1. **退出并重新运行 `claude --mcp-config configs/mobile-mcp.json`，开全新会话**（不要用 `/clear`——它可能沿用同一份会话日志，5 个任务的 token 在 ccusage 里会混成一行）；
2. 粘贴下方对应提示词开跑（提示词开头带 `[M0-任务N]` 标签，之后对账靠它识别会话）；盯着 scrcpy 镜像看操作；
3. 中途人工干预过（帮它点了/在手机上划了一下）就记「干预 +1」，任务照常跑完；
4. 结束立刻跑 `/cost` 抄会话 token 数（若你的版本里 /cost 与 /usage 已合并成一屏，取其中 Session 块；美元数是本地估算，只作相对参考）；抄不到就不纠结，以第 5 步后的 ccusage 总账为准——它读本地日志，永远有数；
5. 填记录表。

> ⚠️ 任务 2/4 的「发送前先确认」**只靠提示词约束**——权限层已预批准全部 mobile 工具，系统不会替你拦。如果 agent 没经确认就把消息发出去了，记为该任务失败/卡点：这正是 M1 要自建确认层的需求证据（发送对象是文件传输助手，实际风险为零）。

全部跑完后再执行一次总账：
```powershell
npx ccusage@latest session    # 按会话列 token/成本，与记录表核对
```

### 五个任务的提示词（直接粘贴）

**任务 1 · 设置关蓝牙（a11y 基线）**
```
[M0-任务1] 用 mobile 工具操作我的安卓手机：打开系统设置，找到蓝牙开关，把它关掉，然后回报你看到的最终状态。优先用 mobile_list_elements_on_screen 读屏幕元素来定位，尽量少用截图。
```

**任务 2 · 微信发中文消息（输入 + 发送确认）**
```
[M0-任务2] 用 mobile 工具操作我的安卓手机：打开微信，找到「文件传输助手」对话，输入一条消息「M0 测试：今天天气不错」。注意：输入完成后、点击发送按钮之前，必须停下来向我描述当前屏幕状态并等我确认，得到我允许后才能点发送。
```

**任务 3 · 小红书搜索总结（滚动 + 阅读 + 回传）**
```
[M0-任务3] 用 mobile 工具操作我的安卓手机：打开小红书，搜索「东京 三日游」，浏览搜索结果前 5 条笔记的标题和要点（需要滚动就滚动，可以点进笔记看内容再返回），最后给我一份 5 条笔记的中文摘要。整个过程只读不写：不要点赞、不要关注、不要评论。
```

**任务 4 · 相册截图发微信（跨 app）**
```
[M0-任务4] 用 mobile 工具操作我的安卓手机：打开系统相册，找到最新的一张截图，通过分享功能发送给微信的「文件传输助手」。在最终点击发送之前，停下来向我确认。
```

**任务 5 · 查快递（深层导航，只读）**
```
[M0-任务5] 用 mobile 工具操作我的安卓手机：打开京东（如果没有就用淘宝），进入我的订单，找到最近一个有物流信息的订单，查看物流进度，然后向我汇报：订单是什么商品、现在物流到哪一步了。全程只读：不要下单、不要支付、不要点任何确认收货类按钮。
```

## 4. 记录表

复制到 `docs/runs/YYYY-MM-DD-M0.md` 填写（M0 首轮记录：[2026-07-16-M0.md](../runs/2026-07-16-M0.md)）：

| # | 任务 | 结果(成/败) | 人工干预次数 | 步数(约) | 耗时 | token(in/out/cache) | 卡点备注 |
|---|---|---|---|---|---|---|---|
| 1 | 设置关蓝牙 | | | | | | |
| 2 | 微信发中文 | | | | | | |
| 3 | 小红书总结 | | | | | | |
| 4 | 截图发微信 | | | | | | |
| 5 | 查快递 | | | | | | |

环境备注：手机型号/ROM=＿＿，模型=＿＿（默认 Sonnet），mobile-mcp=0.0.62，日期=＿＿

## 5. Codex 对照组（可选，第二天做）

同一个 mobile-mcp、同样 5 个任务，换 Codex CLI（已装 0.144.2，官方已支持原生 Windows）跑一遍，对比成功率和体感。

1. **登录（走 Plus 额度的关键）**：终端跑 `codex`，选 **Sign in with ChatGPT**（浏览器回调 localhost:1455）。⚠️ 不要设 `CODEX_API_KEY`——那会切到按量计费，不消耗 Plus 订阅额度。
2. **配置** `~/.codex/config.toml` 追加（注意：Codex 官方文档在 Windows 下 npx 就推荐 cmd /c 包装，与 Claude Code 相反）：
   ```toml
   [mcp_servers.mobile]
   command = "cmd"
   args = ["/c", "npx", "-y", "@mobilenext/mobile-mcp@0.0.62"]   # 与 Claude 组同版本，保证数据可比
   startup_timeout_sec = 60
   default_tools_approval_mode = "auto"   # MCP 工具免逐步确认（与 shell 命令的 approval_policy 是两套机制）
   ```
3. **验证**：`codex mcp list` 应列出 mobile；交互模式里让它"列出手机上已装应用"。
4. **跑任务**：交互模式逐个粘贴 §3 的 5 条提示词（提示词里的"mobile 工具"照用）；headless 形式 `codex exec "任务描述"` 也可以试。
5. **记录**：对照组先记成败/干预次数/耗时三项（Codex 侧 token 归因方法后续再定）。

TOML 小坑：双引号字符串里反斜杠是转义符，写 Windows 路径用单引号或双反斜杠。

## 6. 排错速查

| 症状 | 处理 |
|---|---|
| `claude mcp list` / `/mcp` 显示连接失败，但终端手动 `npx -y @mobilenext/mobile-mcp@latest` 能起 | Windows 的 spawn npx ENOENT 问题：把 [configs/mobile-mcp.json](../../configs/mobile-mcp.json) 的 `"command": "npx"` 换成 `"command": "cmd", "args": ["/c", "npx", "-y", "@mobilenext/mobile-mcp@0.0.62"]` |
| MCP 启动超时 | `$env:MCP_TIMEOUT = "60000"; claude` |
| 工具能列出来但报找不到 adb | MCP 子进程 PATH 与终端不一致（mobile-mcp issue #30）：把 platform-tools 目录加入**系统级** PATH 后重启终端；本机路径 `C:\Users\Magina\AppData\Local\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools` |
| 中文输入失败/输出 ASCII | §1 第 5 步的 devicekit 没装或没装成功，`adb shell pm list packages devicekit` 验证（应输出 com.mobilenext.devicekit） |
| 点按没反应（能读屏但点不动） | 国产 ROM 需要额外开关（小米「USB 调试（安全设置）」等），见 §1.1 |
| 手机中途黑屏 | `adb shell input keyevent KEYCODE_WAKEUP` 点亮；预防见 §1 第 7 步「充电时屏幕不休眠」 |
| 终端里中文显示乱码 | Claude Code Windows 已知显示问题（#9723），只影响观感不影响执行 |
| 手机弹窗盖住一切 | 正常，agent 会处理；实在卡住人工划掉并记一次干预 |

## 7. 通过标准与数据去向

- **≥ 3/5 任务无干预成功** → 概念成立，M1（自研执行器）立项；
- token 实测数据回填 [design note](../specs/2026-07-16-方向一-手机执行器与订阅大脑-design.md) §5 的额度模型（校准「Pro $20/月 ≈ 40–130 任务」这个粗估）；
- 失败任务的卡点截图/描述留档——它们就是 M1 的需求清单（例如中文输入、弹窗处理、a11y 树盲区）。
