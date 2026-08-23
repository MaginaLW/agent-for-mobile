# 知识库索引（渐进式披露入口）

> **载入纪律：按需读单册，不整目录读。** 遇到左列情况才载入右列文件；没遇到就不读。CLAUDE.md 文档地图只指到本文件。

## 载入路由

| 遇到什么情况 | 载入 |
|---|---|
| Android 平板接入、姿态/大屏/多窗/任务栏/浮动 IME | [android/tablet.md](android/tablet.md) |
| 历史 vivo 手机真机操作 | [android/vivo-originos.md](android/vivo-originos.md) |
| Android 版本级行为疑问（剪贴板/开关权限/a11y/截图节流）、adb/uiautomator 工具链坑 | [android/common.md](android/common.md) |
| 要用系统命令（dumpsys/cmd/svc/am/pm/settings）、Shizuku、IME 切换 | [android/sys-cli.md](android/sys-cli.md)（🔵 多为查阅未实测） |
| 换测试机 / 其他安卓厂商 | [android/other-vendors.md](android/other-vendors.md) |
| 操作微信 | [apps/wechat.md](apps/wechat.md) |
| 操作小红书 | [apps/xiaohongshu.md](apps/xiaohongshu.md) |
| 操作京东 | [apps/jd.md](apps/jd.md) |
| 找深链（所有 app + 系统，含 🔵 候选区） | [apps/deeplinks.md](apps/deeplinks.md) |
| 算成本账 / 额度容量 | [brain/cost.md](brain/cost.md) |
| 大脑侧链路（headless/挂载/两段式） | [brain/harness.md](brain/harness.md) |
| 涉及 iOS / 苹果 | [ios/README.md](ios/README.md)（非目标边界，勿重复调研） |

## 目录结构与归档规则

```
knowledge/
├─ android/          # 安卓阵营：common · tablet(当前平板基线) · vivo-originos(历史手机基线) · other-vendors · sys-cli
├─ ios/              # 苹果阵营：边界占位
├─ apps/             # 每 app 一册（wechat/xiaohongshu/jd/…）+ deeplinks 注册表
└─ brain/            # 大脑侧：cost(成本校准) · harness(链路坑)
```

1. **新坑归档**：先问"这是谁的坑"——Android 版本的进 `android/common.md`；ROM 特有的进对应厂商册；app 特有的进对应 app 册；成本/链路的进 `brain/`。跨类就拆开各归各家，别写成流水账。
2. **新 app**：`apps/<拼音或通称>.md` 一册；深链统一进 `apps/deeplinks.md`（技能包 assets 的同源，改它记得同步 `app/gateway/src/main/assets/skillpack/`）。
3. **新厂商**：先记 `android/other-vendors.md`，上真机后拆独立册。
4. **实测 vs 查阅分区**：实测结论注设备+日期；云端查阅一律标 🔵 未实测，验证通过才转正。
