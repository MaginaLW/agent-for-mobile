# 实测深链库

> 深链按 app 逐个实测建库（M0 结论：系统 intent 反而不可靠，app 自定义 scheme 更稳）。这份库是将来 App 技能包的原料——每条命中都省掉多步导航+中文输入的真金白银。

| App / 系统 | 深链 | 效果 | 实测（设备/日期） |
|---|---|---|---|
| 小红书 | `xhsdiscover://search/result?keyword=<urlencoded>` | ✅ 一步直达搜索结果页 | vivo V2352A / 2026-07-16 |
| 系统设置 | `am start -a android.settings.BLUETOOTH_SETTINGS` | ❌ OriginOS 上不把蓝牙页带到前台 | vivo V2352A / 2026-07-16 |
| 系统设置 | 主设置 intent（`android.settings.SETTINGS`） | ✅ 正常 | vivo V2352A / 2026-07-16 |

## 云端查阅候选（🔵 未实测，2026-07-17 整理，入库前逐条真机验证并移入上表）

> 性质同 [../android/sys-cli.md](../android/sys-cli.md)：这些是查阅所得的候选深链，**生效性强依赖 app 版本**（微信尤其善变，见下），真机验证通过才算数、才注设备与日期上移正表。M1 真机日 / 随任务积累。

| App | 候选深链 | 用途 | 风险/备注 |
|---|---|---|---|
| 微信 | `weixin://` | 仅打开 app | 主 scheme，最稳 |
| 微信 | `weixin://dl/business/?t=<TICKET>` | 打开小程序 | TICKET 服务端生成、**每日更新**——非固定深链，自用场景难利用 |
| 微信 | `weixin://scanqrcode`、`weixin://dl/scan` | 扫一扫 | ⚠️ 查阅明确指出 `dl/scan`、`dl/moments`、`dl/settings` 等**多数已失效**，别指望 |
| 微信 | — | **直达指定聊天：无公开深链**（spec §10 不可实现边界已记） | 会话入口仍需 UI（搜索框/列表点击） |
| 京东 | `openapp.jdmobile://` | 打开 app | 主 scheme |
| 京东 | `openapp.jdmobile://virtual?params=<URLENCODED_JSON>`，JSON=`{"category":"jump","des":"productList","keyWord":"<词>","from":"search"}` | 搜索结果页 | params 是 urlencode 后的 JSON；验证任务 5 前半段能否省掉手工导航 |
| 京东 | 同上 des=`productDetail`，JSON 带 `"skuId":"<id>"` | 商品详情 | |
| 京东 | 订单列表：待查确切 des（M0 走 UI：我的→全部订单） | 物流任务前半段 | 若命中可省 3–4 步 |
| 淘宝 | `taobao://` | 打开 app | |
| 淘宝 | `taobao://s.taobao.com?q=<词>` | 搜索 | 结构比京东简单 |
| 天猫 | `tmall://` | 打开 app | |
| 支付宝 | `alipay://` | 打开 app | ⚠️ 支付类高危，仅只读/打开场景；任何支付动作走两段式且系统支付框永不自动化（spec §10 红线） |
| 支付宝 | `alipayqr://platformapi/startapp?saId=10000007` | 扫一扫 | saId 参数化，另有付款码 saId 等（高危，不主动用） |

## 使用原则

- 深链失败必须有 UI 导航兜底（执行器 `open_uri` 的内建逻辑；M1a 已实现：命中注册表则执行后验前台，失败抛 E_VERIFY_FAIL 带 UI 兜底提示）。
- 新深链入库前先在目标设备实测，注明设备与日期；云端候选先进上面的 🔵 表，验证通过才上正表。
- 微信深链整体不可靠（官方善变 + 无聊天直达），微信类任务仍以 UI/分享通道为主。
