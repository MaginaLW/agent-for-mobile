# 钉定 PowerShell 迁出自更新缓存（2026-09-05）

## 起因：信任根被放在了一个会自更新的目录里

09-02 全量门 11/11 绿，09-05 再跑时 C1b 门失败。排查发现**主机侧两处独立漂移**，都不是仓库改动引起：

| 项 | 09-02 冻结 | 09-05 观测 |
|---|---|---|
| `pwsh.exe` SHA-256 | `db6dd811…458f` | `362a356c…d139` |
| 版本 | 7.6.4 | 7.6.5 |
| 运行时树 | 983 文件 / 54 目录 / 296034085 B | 658 / 40 / 256592846 |
| 写入时间 | — | `2026-09-05T03:50:17Z` |

钉定运行时原先位于 Codex 的运行时缓存内。该缓存旁留有 **7 个 `codex-runtime-install-*` 暂存目录，
全部为 09-04**，即当天反复安装的痕迹；本机 `.cache` 下**只剩这一个 `pwsh.exe`，7.6.4 无备份**。

**结论不是"再钉一次"，是钉错了地方。** 把信任根放在第三方会自行重装的缓存目录里，
结构上就保证了它会被打穿——和 Git 那次「多了一个文件、重装治不了」是同一族问题：
**恢复手段作用不到真正的成因上。**

## 处置（用户 2026-09-05 拍板：装到项目自控位置并钉那份）

**没有下载**：目标字节已在本机，且来源可信——迁移前在原位复核 Authenticode，
`pwsh.exe` 为 `Valid`，签名者 `CN=Microsoft Corporation`，签发者 `Microsoft Code Signing PCA 2024`，
带时间戳；同树 **517 个 `.exe`/`.dll` 中签名非 `Valid` 的为 `0` 个**。
因此选择「复制 + 冻结」而不是重走下载/验签阶梯。

迁移到 `<repos-root>/_toolchain/powershell-7.6.5`（沿用同级 `_archived-runs` 的下划线前缀惯例，
项目自控、非缓存、无需提权）。流程：

1. 源侧枚举并拒绝任何 reparse point，得 658 文件；逐文件先算 SHA-256；
2. 复制；
3. **复制后逐文件重算并比对**（不信任 `Copy-Item`）：`missing=0`、`mismatch=0`；
4. 658 个文件全部置只读冻结；
5. 按与 Git 信任根同族的规则编目（Ordinal 排序 → `relpath=sha256:hex` 以 LF 连接 → UTF-8 no-BOM 的 SHA-256）。

## 冻结值

| 项 | 值 |
|---|---|
| `pwsh.exe` SHA-256 | `362a356ce7f0940ec74f73a8fc2c990a2cc24a38a11c90bbd8eca947110ad139` |
| 版本 | `7.6.5` |
| Authenticode（新路径复核） | `Valid` / `CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US` |
| file count | `658` |
| dir count | `40` |
| total bytes | `256592846` |
| tree catalog | `sha256:7b68ced0765719566c1645426fea18ccfe5572f3508dc294655c7abafe03076d` |

## 连带影响：三件冻结工件失效

它们把旧 `pwsh` 的 SHA/版本焊死在内部，必须按新钉定值重造：

| 工件 | 旧 pwsh SHA 出现次数 | `"7.6.4"` 出现次数 |
|---|---:|---:|
| `launcher-015835c-r11.ps1` | 1 | 3 |
| `render-final-r12-015835c.ps1` | 1 | 1 |
| `preflight-a661f36-r13.ps1`（r14 的源 leaf） | 1 | 0 |

`helper-015835c-r11.ps1` 不绑 pwsh（0 处），不受影响。
仓库侧**没有**钉 pwsh——`tablet-layout-c1b-build-env.ps1` 无相关常量，
唯一 tracked 引用是 `knowledge/brain/harness.md` 里的说明行。

## 仍未闭合

- **符号链接特权**：实测 `SeCreateSymbolicLinkPrivilege` 未持有、未提权、
  `AllowDevelopmentWithoutDevLicense` 注册键不存在，故 `CreateSymbolicLink` 必失败，
  C1b verifier 子套件产生 2 个 skip、门要求 exact 值因而失败。用户 09-05 拍板**开启开发者模式**，
  该动作需在系统设置中由用户完成，尚未执行。
  （09-02 该门通过，据此**推断**当时特权在位；但当天未直接量过特权本身，此条标注为推断。）
- clean SHA 需在代码改动与上述两项闭合后重新固定并重跑全量门。
