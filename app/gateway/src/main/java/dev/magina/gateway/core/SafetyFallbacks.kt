package dev.magina.gateway.core

/**
 * 危险路径上给大脑的 `fallback` 措辞。
 *
 * # 为什么集中在这里，而不是内联在抛错处
 *
 * `fallback` 是**直接指挥大脑下一步动作**的文本，与站规
 * `scripts/prompts/gateway-executor-preamble.md` §4 是同一件事的两面。内联的字符串
 * **没有任何判据看得见它**，于是它与站规的漂移无人发现——2026-08-02 一口气查出五处
 * fallback 写着"输出 `[AWAIT_CONFIRM]`"，而站规恰恰明令这些终态不得输出它
 * （见 knowledge「判据看不见的东西就会烂掉」）。放在这里就能被离线用例逐条钉住。
 *
 * # 为什么这些码一律是终态，没有例外
 *
 * 站规 §4 把 `E_CONFIRM_TIMEOUT`、`E_PERM_MISSING`、`E_CHANNEL_DOWN` 等逐个点名列为终态，
 * 并限定 `[AWAIT_CONFIRM]` **只允许在尚未调用任何危险工具前**发现纯人工前置条件时使用。
 * 这里涉及的每一处都发生在危险工具**已经在调用中**——大脑调了 `press_key`，工具返回了错误码。
 *
 * 还有一条不依赖措辞的机械理由，比引用站规更硬：
 * **`dispatch.ps1 -Confirm` 对 gateway 暂停件的终态码检查里，这几个码全在拒绝恢复的名单上。**
 * 也就是说，就算大脑照着旧 fallback 输出了 `[AWAIT_CONFIRM]`、派单方也落盘了暂停件，
 * 下一步 `-Confirm` 也会机械拒绝。旧措辞指的是一条**保证走不通**的路：白烧一条腿、
 * 生成一个永远用不了的暂停件，然后人还要被告知"拒绝恢复"。
 */
object SafetyFallbacks {

    /** 所有 safety 终态共用的那句。改它等于改站规的执行面，两边必须一起改。 */
    const val TERMINAL: String =
        "按站规报告「结果：失败」；不得输出 [AWAIT_CONFIRM]，不得重试同一危险动作，也不得换路达到相同副作用"

    /** 人没在确认窗口内做决定。危险动作没执行，但这一腿就此终结。 */
    const val CONFIRM_TIMEOUT: String =
        "$TERMINAL。并写明：确认窗口内无人决定，本次危险动作未执行"

    /** 悬浮窗权限没授予，确认卡根本弹不出来——这是设备配置问题，报告里要说清怎么修。 */
    const val OVERLAY_PERMISSION_MISSING: String =
        "$TERMINAL。并写明：网关缺少悬浮窗权限，需用户在系统设置中授予后重跑"

    /** 确认通道本身坏了（主线程、Handler、窗口管理器）。 */
    const val OVERLAY_CHANNEL_DOWN: String =
        "$TERMINAL。并写明确认通道不可用的具体表现，供人排查"
}
