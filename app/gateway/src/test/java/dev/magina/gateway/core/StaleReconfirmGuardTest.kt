package dev.magina.gateway.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 限次重弹的判据。
 *
 * **这条机制在当前站规下走不到**（2026-08-02 用户重新拍板：维持「安全失败即终态」，
 * 不开有界重试口子）——大脑在第一次 stale 就必须停下报告失败，计数器连 1 都到不了。
 * 保留它作为纵深防御：上限本身没错，将来若真有路径能重试，上限仍该是 2。
 *
 * 键的三条不变量仍逐条验（它们不依赖重弹路径怎么实现）：
 * 1. 不得把两个不同的语义动作并成一次（否则第二个动作会莫名其妙被拒）；
 * 2. 不得把同一个语义动作的重试拆成多次（否则限次形同虚设，退化回无界循环）；
 * 3. 用尽时给大脑的下一步**必须与站规一致**——见下面那条 fallback 用例。
 */
class StaleReconfirmGuardTest {

    private val strict = FocusIdentity(
        IdentitySource.A11Y,
        "7|com.tencent.mm:id/chat_input|android.widget.EditText|com.tencent.mm|10,20,100,80",
        "ime|0123456789abcdef01234567",
    )

    private fun contextWith(text: String, label: String, preview: String): SafetyContext =
        SafetyContext(
            packageName = "com.tencent.mm",
            activityName = ".ui.LauncherUI",
            revision = 1,
            target = SafetyTarget(
                ref = "r-${text.hashCode()}",
                text = text,
                focusIdentity = strict,
                inputCommitEvidence = InputCommitEvidence(
                    commitId = 1,
                    preview = preview,
                    length = preview.length,
                    sha256 = InputCommitEvidence.sha256(preview),
                    identity = strict,
                    readbackVerified = true,
                    committedAtMs = 0,
                    expiresAtMs = 60_000,
                ),
                preparedTargetEvidence = PreparedTargetEvidence(
                    preparedId = 1,
                    label = label,
                    packageName = "com.tencent.mm",
                    identity = strict,
                    bounds = "[10,20][100,80]",
                    preparedAtMs = 0,
                    expiresAtMs = 60_000,
                ),
            ),
        )

    private fun keyFor(toolName: String, context: SafetyContext): String = StaleReconfirmGuard.key(
        toolName = toolName,
        riskTier = RiskTier.RETRACTABLE,
        targetLabel = context.target?.preparedTargetEvidence?.label,
        contentKey = StaleReconfirmGuard.contentKeyOf(toolName, context),
    )

    /** 不变量 2：同一个语义动作重试时 `ref` 会变、参数指纹不变——键必须仍然相同。 */
    @Test
    fun `retrying the same semantic action keeps one key`() {
        val first = contextWith(text = "发送", label = "文件传输助手", preview = "P0ALLOW-ABC")
        // 重新感知：ref 变了（上面按 text 派生，这里显式换掉），文本与已提交内容不变。
        val second = contextWith(text = "发送", label = "文件传输助手", preview = "P0ALLOW-ABC")
            .let { it.copy(target = it.target!!.copy(ref = "r-refreshed")) }

        assertEquals(keyFor("press_key", first), keyFor("press_key", second))
        assertEquals(keyFor("ui_action", first), keyFor("ui_action", second))
    }

    /** 不变量 1：换了目标会话、换了要发的内容、换了工具，都是另一个语义动作。 */
    @Test
    fun `different semantic actions never share a key`() {
        val base = contextWith(text = "发送", label = "文件传输助手", preview = "P0ALLOW-ABC")
        val otherSession = contextWith(text = "发送", label = "张三", preview = "P0ALLOW-ABC")
        val otherContent = contextWith(text = "发送", label = "文件传输助手", preview = "P0ALLOW-XYZ")
        val otherTarget = contextWith(text = "删除", label = "文件传输助手", preview = "P0ALLOW-ABC")

        assertNotEquals(keyFor("press_key", base), keyFor("press_key", otherSession))
        // press_key 的内容键是**已提交文本的摘要**：换一段文字就是另一件事。
        assertNotEquals(keyFor("press_key", base), keyFor("press_key", otherContent))
        // ui_action 的内容键是目标控件文本：点「删除」与点「发送」是两件事。
        assertNotEquals(keyFor("ui_action", base), keyFor("ui_action", otherTarget))
        assertNotEquals(keyFor("press_key", base), keyFor("ui_action", base))
        assertNotEquals(
            StaleReconfirmGuard.key("press_key", RiskTier.IRREVERSIBLE, "文件传输助手", "x"),
            StaleReconfirmGuard.key("press_key", RiskTier.RETRACTABLE, "文件传输助手", "x"),
        )
    }

    /**
     * B 道点名的两个反例：参数指纹与 ref 都不能直接当键。
     * `press_key(enter)` 的参数恒为 `{key:"enter"}`，指纹跨**不同会话**也完全相同。
     */
    @Test
    fun `neither the args fingerprint nor the ref could serve as the key`() {
        val toWechat = contextWith(text = "发送", label = "文件传输助手", preview = "给助手")
        val toZhangsan = contextWith(text = "发送", label = "张三", preview = "给张三")

        // 若拿参数指纹当键：两次 press_key(enter) 的参数一模一样 → 会被并成一次（违反 1）。
        assertEquals(
            SafetyPolicy.fingerprint(org.json.JSONObject().put("key", "enter")),
            SafetyPolicy.fingerprint(org.json.JSONObject().put("key", "enter")),
        )
        assertNotEquals("而真正的键必须把它们分开", keyFor("press_key", toWechat), keyFor("press_key", toZhangsan))

        // 若拿 ref 当键：重新感知后 ref 必变 → 同一动作的重试被拆开（违反 2）。
        val refreshed = toWechat.let { it.copy(target = it.target!!.copy(ref = "r-new")) }
        assertNotEquals(toWechat.target?.ref, refreshed.target?.ref)
        assertEquals("而真正的键必须把它们串起来", keyFor("press_key", toWechat), keyFor("press_key", refreshed))
    }

    /**
     * **代码不得反过来教大脑违规。**
     *
     * 站规 §4 把 `E_CONFIRM_REQUIRED` 列为终态，明令「立即报告『结果：失败』」且
     * 「不得输出 `[AWAIT_CONFIRM]`、不得重试同一危险动作」。而这条路径原来的 fallback
     * 写的恰恰是"输出 [AWAIT_CONFIRM] 暂停报告"——与站规正面矛盾。
     *
     * 措辞放在纯 Kotlin 常量里就是为了能被这条用例钉住：内联进 ToolRegistry 的字符串
     * 没有任何判据看得见它（那正是它错了这么久都没被发现的原因）。
     */
    @Test
    fun `exhausted fallback follows the station rules instead of contradicting them`() {
        val fallback = StaleReconfirmGuard.EXHAUSTED_FALLBACK

        assertFalse("站规明令不得输出 [AWAIT_CONFIRM]", fallback.contains("[AWAIT_CONFIRM]") &&
            !fallback.contains("不得输出 [AWAIT_CONFIRM]"))
        assertTrue("必须指向站规的常规终态格式", fallback.contains("结果：失败"))
        assertTrue("必须重申不得重试同一危险动作", fallback.contains("不得重试"))
        assertTrue(
            "消息要说清是什么状况，不能只丢一个错误码",
            StaleReconfirmGuard.EXHAUSTED_MESSAGE.contains("批准后") &&
                StaleReconfirmGuard.EXHAUSTED_MESSAGE.contains("${StaleReconfirmGuard.MAX_RECONFIRMS}"),
        )
    }

    @Test
    fun `two reconfirms are allowed and the third is refused`() {
        val guard = StaleReconfirmGuard()

        assertFalse("第一张卡不是重弹", guard.isExhausted("k"))
        guard.recordStaleAfterApproval("k")
        assertFalse("第一次重弹应放行", guard.isExhausted("k"))
        guard.recordStaleAfterApproval("k")
        assertTrue("重弹两次后必须停下", guard.isExhausted("k"))
        assertEquals(2, guard.reconfirmCount("k"))
    }

    @Test
    fun `success clears the counter so the next action starts fresh`() {
        val guard = StaleReconfirmGuard()
        guard.recordStaleAfterApproval("k")
        guard.recordStaleAfterApproval("k")
        assertTrue(guard.isExhausted("k"))

        guard.clear("k")

        assertEquals(0, guard.reconfirmCount("k"))
        assertFalse(guard.isExhausted("k"))
    }

    /** 没有 TTL 的话，一个跑满次数的键会永久拒绝后续同名动作。 */
    @Test
    fun `counter expires so a much later action is not punished`() {
        var now = 0L
        val guard = StaleReconfirmGuard(ttlMs = 1_000, clock = { now })
        guard.recordStaleAfterApproval("k")
        guard.recordStaleAfterApproval("k")
        assertTrue(guard.isExhausted("k"))

        now += 1_001

        assertFalse("过期后从零开始", guard.isExhausted("k"))
        assertEquals(0, guard.reconfirmCount("k"))
    }

    @Test
    fun `counters are per key`() {
        val guard = StaleReconfirmGuard()
        guard.recordStaleAfterApproval("a")
        guard.recordStaleAfterApproval("a")

        assertTrue(guard.isExhausted("a"))
        assertFalse("另一个语义动作不该被连坐", guard.isExhausted("b"))
    }

    @Test
    fun `blank key parts degrade without colliding across tools`() {
        assertNotEquals(
            StaleReconfirmGuard.key("press_key", RiskTier.IRREVERSIBLE, null, null),
            StaleReconfirmGuard.key("ui_action", RiskTier.IRREVERSIBLE, null, null),
        )
    }
}
