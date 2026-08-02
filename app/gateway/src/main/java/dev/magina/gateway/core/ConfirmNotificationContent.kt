package dev.magina.gateway.core

/**
 * 通知栏审批的三层文案（批次 2，B 道拍板 §5）。
 *
 * 三层 surface 各自受的约束完全不同，所以文案也必须分开生成——把它们合成一份，
 * 明文预览迟早会跟着跑到锁屏上去：
 *
 * - [publicLine] **锁屏摘要 / 折叠态**：任何拿起手机的人都看得到。只放"档位 · 动作 → 目标"，
 *   **明文预览 / SHA-256 / 参数指纹 / 焦点几何一律不出现**。
 * - [expandedText] **展开态**（`BigTextStyle`，需解锁）：三项锚点 = 档位 + 目标会话 + 明文预览。
 * - L3（现有确认卡）：8 项原样不动，唯一增量是档位标注，见 [tierEvidenceLine]。
 *
 * 纯 Kotlin，可离线单测——**"明文有没有漏到锁屏上"这种判据必须能被用例钉住**，
 * 不能只靠人跑一次真机看一眼。
 */
object ConfirmNotificationContent {

    /** 通知标题：固定，不含任何本次动作的内容。 */
    const val TITLE: String = "⚠ Agent 请求执行危险操作"

    /**
     * 档位短名，用于锁屏那一行。用户在锁屏上第一眼要判断的是"这条要不要立刻展开"，
     * 档位是唯一能回答这个问题的字段。
     */
    fun tierLabel(tier: RiskTier): String = when (tier) {
        RiskTier.IRREVERSIBLE -> "不可逆"
        RiskTier.RETRACTABLE -> "可撤回"
    }

    /**
     * 锁屏 / 折叠态那一行：`[档位] · [动作] → [目标]`。
     *
     * **它同时是 `setPublicVersion()` 的正文**，所以这里出现什么，等于同意它出现在锁屏上。
     * 目标只放会话 label（如"文件传输助手"）——那是收件人，不是消息内容。
     */
    fun publicLine(tier: RiskTier, action: String, target: String): String {
        val safeAction = action.ifBlank { "危险动作" }
        val safeTarget = target.ifBlank { "未知目标" }
        return "${tierLabel(tier)} · $safeAction → $safeTarget"
    }

    /**
     * 展开态正文：三项锚点（B 道决定一）。
     *
     * 没选进来的两项与理由：**前台包**与"目标会话"冗余；**输入长度**只多告诉用户"还剩多少"——
     * 预览超长时截断处会补 `…`（[InputCommitEvidence.PREVIEW_LIMIT]），"有没有被截"本来就看得见。
     */
    fun expandedText(
        tier: RiskTier,
        target: String,
        preview: String?,
    ): String = buildString {
        append("风险档位：").append(tierDetail(tier))
        append("\n目标会话：").append(target.ifBlank { "不可识别" })
        append("\n实际输入预览：").append(
            when {
                preview == null -> "（本次动作没有输入内容）"
                preview.isBlank() -> "（空）"
                else -> preview
            }
        )
    }

    /**
     * 档位详述，进展开态与 L3 确认卡。
     *
     * II 级**不编造撤回时长**：撤回窗口由目标 App 定，网关无从得知；微信 2 分钟是众所周知的
     * 事实所以点名，其余一律说"以该 App 规则为准"。宁可说少，不可在确认卡上放一个我们
     * 没有依据的数字——那和自举身份不许编造 activity 是同一条规矩。
     */
    fun tierDetail(tier: RiskTier, targetPackage: String = ""): String = when (tier) {
        RiskTier.IRREVERSIBLE -> "I 级 · 不可撤销（做完之后你没有自救手段）"
        RiskTier.RETRACTABLE -> {
            val window = RETRACT_WINDOWS[targetPackage]
            if (window != null) "II 级 · 有撤回窗口（$window）"
            else "II 级 · 有撤回窗口（时长以该 App 规则为准）"
        }
    }

    /** L3 确认卡上的档位标注行。8 项证据一字不动，这是唯一的增量。 */
    fun tierEvidenceLine(tier: RiskTier, targetPackage: String = ""): String =
        "风险档位：" + tierDetail(tier, targetPackage)

    /** 只放**有据可查**的撤回窗口；不确定的 App 一律不进这张表。 */
    private val RETRACT_WINDOWS: Map<String, String> = mapOf(
        "com.tencent.mm" to "微信约 2 分钟",
    )
}
