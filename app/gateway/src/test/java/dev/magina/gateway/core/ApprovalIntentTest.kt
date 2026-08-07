package dev.magina.gateway.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * spec `2026-08-02-语义意图审批` §2.3 那张判据对照表的逐行用例，**每一行都带反例**。
 * 表里任何一行的松动都是安全姿态变更；这些用例就是它的看门人。
 */
class ApprovalIntentTest {

    private val imeSessionId = "ime|0123456789abcdef01234567"
    private val nodeId =
        "7|com.tencent.mm:id/chat_input|android.widget.EditText|com.tencent.mm|10,20,100,80"
    private val identity = FocusIdentity(IdentitySource.A11Y, nodeId, imeSessionId)

    private fun context(
        packageName: String = "com.tencent.mm",
        label: String = "文件传输助手",
        sha256: String = SHA_A,
        length: Int = 18,
    ) = SafetyContext(
        packageName = packageName,
        activityName = "com.tencent.mm/.ui.LauncherUI",
        revision = 1,
        target = SafetyTarget(
            focusIdentity = identity,
            focusedInputBounds = "[10,20][100,80]",
            inputCommitEvidence = InputCommitEvidence(
                commitId = 1,
                preview = "P0ALLOW-3479AHKMPT",
                length = length,
                sha256 = sha256,
                identity = identity,
                readbackVerified = true,
                committedAtMs = 1_000,
                expiresAtMs = 121_000,
            ),
            preparedTargetEvidence = PreparedTargetEvidence(
                preparedId = 1,
                label = label,
                packageName = packageName,
                identity = identity,
                bounds = "[10,20][100,80]",
                preparedAtMs = 1_000,
                expiresAtMs = 121_000,
            ),
        ),
    )

    private fun intent(
        tier: RiskTier = RiskTier.RETRACTABLE,
        targetPackage: String = "com.tencent.mm",
        targetLabel: String = "文件传输助手",
        sha256: String? = SHA_A,
        length: Int? = 18,
        createdAtMs: Long = 1_000,
    ) = ApprovalIntent(
        intentId = "intent-1",
        riskTier = tier,
        actionKind = "发送消息",
        targetPackage = targetPackage,
        targetLabel = targetLabel,
        contentSha256 = sha256,
        contentLength = length,
        createdAtMs = createdAtMs,
    )

    private fun match(
        intent: ApprovalIntent = intent(),
        context: SafetyContext = context(),
        nowMs: Long = 1_500,
        ttlMs: Long = 120_000,
    ) = IntentMatchPolicy.matches(intent, context, nowMs, ttlMs)

    // —— 正例：语义一致就放行，**实现细节变了不拦** ——

    @Test
    fun `same intent matches even after focus identity and bounds changed`() {
        // 这正是本篇的全部收益：人机延迟里 IME 会话会重建、键盘一起落会改几何，
        // 而"往文件传输助手发这条消息"没有变。今天的逐字段相等会在这里判 stale。
        val moved = context().let { base ->
            val other = FocusIdentity(IdentitySource.A11Y, nodeId.replace("chat_input", "other"), imeSessionId)
            base.copy(
                activityName = "com.tencent.mm/.ui.ChatUI",
                target = base.target!!.copy(
                    focusIdentity = other,
                    focusedInputBounds = "[9,9][9,9]",
                    inputCommitEvidence = base.target!!.inputCommitEvidence!!.copy(identity = other),
                    preparedTargetEvidence = base.target!!.preparedTargetEvidence!!.copy(
                        identity = other,
                        bounds = "[9,9][9,9]",
                    ),
                ),
            )
        }

        assertEquals(IntentMatch.Matched, match(context = moved))
    }

    @Test
    fun `intent without content matches a context that has no input evidence`() {
        // 点击类动作没有输入内容；不能因为"没有 sha256"就平凡通过，也不能反过来强求它有。
        val clickIntent = intent(sha256 = null, length = null)
        val noInput = context().let { it.copy(target = it.target!!.copy(inputCommitEvidence = null)) }

        assertEquals(IntentMatch.Matched, IntentMatchPolicy.matches(clickIntent, noInput, 1_500, 120_000))
    }

    // —— 反例：一行一条 ——

    @Test
    fun `expired intent never matches`() {
        val result = match(nowMs = 1_000 + 120_000)

        assertTrue((result as IntentMatch.Mismatch).reason.contains("过期"))
    }

    @Test
    fun `unknown foreground never matches`() {
        val unknown = context().copy(packageName = "", foregroundKnown = false)

        assertTrue((match(context = unknown) as IntentMatch.Mismatch).reason.contains("前台身份未知"))
    }

    @Test
    fun `package change is a hard mismatch`() {
        val other = context(packageName = "com.android.chrome", label = "文件传输助手")

        val reason = (match(context = other) as IntentMatch.Mismatch).reason
        assertTrue(reason, reason.contains("前台包与意图不符"))
        // 逐条点名 + 旧值→新值：把三项合并成一句话是真机排查里最贵的反模式。
        assertTrue(reason, reason.contains("com.tencent.mm") && reason.contains("com.android.chrome"))
    }

    @Test
    fun `target label change is a mismatch`() {
        val reason = (match(context = context(label = "张三")) as IntentMatch.Mismatch).reason

        assertTrue(reason, reason.contains("目标会话与意图不符"))
        assertTrue(reason, reason.contains("文件传输助手") && reason.contains("张三"))
    }

    @Test
    fun `content digest change is a mismatch`() {
        val reason = (match(context = context(sha256 = SHA_B)) as IntentMatch.Mismatch).reason

        assertTrue(reason, reason.contains("内容摘要与意图不符"))
    }

    @Test
    fun `content length change is a mismatch even when digest is somehow equal`() {
        val reason = (match(context = context(length = 19)) as IntentMatch.Mismatch).reason

        assertTrue(reason, reason.contains("内容长度与意图不符"))
    }

    @Test
    fun `missing prepared target evidence is a mismatch not a pass`() {
        val stripped = context().let { it.copy(target = it.target!!.copy(preparedTargetEvidence = null)) }

        assertTrue((match(context = stripped) as IntentMatch.Mismatch).reason.contains("目标会话证据"))
    }

    @Test
    fun `missing input evidence is a mismatch when the intent locked content`() {
        val stripped = context().let { it.copy(target = it.target!!.copy(inputCommitEvidence = null)) }

        assertTrue((match(context = stripped) as IntentMatch.Mismatch).reason.contains("输入提交证据"))
    }

    @Test
    fun `prepared evidence from another package is a mismatch`() {
        val crossed = context().let { base ->
            base.copy(
                target = base.target!!.copy(
                    preparedTargetEvidence = base.target!!.preparedTargetEvidence!!.copy(
                        packageName = "com.android.chrome",
                    ),
                ),
            )
        }

        assertTrue((match(context = crossed) as IntentMatch.Mismatch).reason.contains("目标会话证据的包"))
    }

    // —— 一次性与不可重放（spec §3） ——

    @Test
    fun `intent is consumed exactly once`() {
        val store = IntentApprovalStore()
        val one = intent()
        store.open(one)

        assertNotNull(store.consume(one.intentId))
        assertNull("意图被消费第二次就是可重放令牌", store.consume(one.intentId))
        assertFalse(store.isPending)
    }

    @Test
    fun `a second confirmation replaces the pending intent`() {
        val store = IntentApprovalStore()
        store.open(intent())
        store.open(intent().copy(intentId = "intent-2"))

        assertNull("旧意图必须失效", store.consume("intent-1"))
    }

    @Test
    fun `discard makes the intent unusable`() {
        val store = IntentApprovalStore()
        store.open(intent())
        store.discard("intent-1")

        assertNull(store.consume("intent-1"))
    }

    // —— 三个时钟（spec §2.4） ——

    @Test
    fun `the five minutes the user decided is the foreground wait budget`() {
        // 用户拍的是"批准之后最多隔多久回到微信还算数"——那对应的是**等前台预算**，
        // 不是只有意图有效期。这条断言就是防止那个决定被改在错误的旋钮上。
        val clocks = IntentApprovalClocks()

        assertEquals(300_000L, clocks.foregroundWaitBudgetMs)
        assertEquals(90_000L, clocks.decisionTimeoutMs)
        // 意图必须盖住整段等待，且不再等于证据 TTL（选项 C 之后耦合理由已消失）。
        assertTrue(clocks.intentTtlMs >= clocks.foregroundWaitBudgetMs)
        assertEquals(InputCommitEvidenceStore.DEFAULT_TTL_MS, clocks.evidenceTtlMs)
    }

    @Test
    fun `an intent that expires before the wait ends is rejected at construction`() {
        // 这正是"决定悄悄落空"的形态：人在预算内回来了，意图却先过期，
        // 现场看到的是一条与今天长得一模一样的 E_STALE_REF。
        val error = runCatching {
            IntentApprovalClocks(foregroundWaitBudgetMs = 300_000, intentTtlMs = 120_000)
        }.exceptionOrNull()

        assertTrue(error is IllegalArgumentException)
        assertTrue(error!!.message!!.contains("等于白做"))
    }

    @Test
    fun `a wait longer than the evidence ttl demands a rebuild channel`() {
        // 没有重建通道时，5 分钟预算必然以 E_VERIFY_FAIL 收场——数字写得再大也兑现不了。
        // 宁可在构造期炸，不要在真机上炸。**断言挂在装配层**：那里能看见通道到底装没装
        // （`!= null`），而时钟只能拿一个可以写错的布尔当依据。
        val error = runCatching {
            IntentApproval(intentIdFactory = { "i" }, awaitForeground = { _, _ -> true })
        }.exceptionOrNull()

        assertTrue(error is IllegalArgumentException)
        assertTrue(error!!.message!!.contains("证据重建通道"))

        // 装了通道就自洽；预算落回证据 TTL 之内时不装也自洽。
        IntentApproval(
            intentIdFactory = { "i" },
            awaitForeground = { _, _ -> true },
            rebuildEvidence = { EvidenceRebuild.Unverified("stub") },
        )
        IntentApproval(
            intentIdFactory = { "i" },
            awaitForeground = { _, _ -> true },
            clocks = IntentApprovalClocks(foregroundWaitBudgetMs = 30_000),
        )
    }

    @Test
    fun `test scaffolding may shorten the wait but never lengthen it`() {
        val clocks = IntentApprovalClocks()

        assertEquals(20_000L, clocks.withShorterForegroundWait(20_000).foregroundWaitBudgetMs)
        // 延长会让"人走开多久还算数"被调用方悄悄改掉，而那是用户拍板的行为。
        assertTrue(
            runCatching { clocks.withShorterForegroundWait(600_000) }.exceptionOrNull()
                is IllegalArgumentException,
        )
    }

    @Test
    fun `only the retractable tier gets a wait budget`() {
        val clocks = IntentApprovalClocks()

        assertEquals(IntentApprovalClocks.DEFAULT_FOREGROUND_WAIT_BUDGET_MS, clocks.foregroundWaitBudgetFor(RiskTier.RETRACTABLE))
        // I 级批准与执行仍然紧挨着：页面等不起，而"批准了一笔转账、几分钟后才发生"本身也不好。
        assertEquals(0L, clocks.foregroundWaitBudgetFor(RiskTier.IRREVERSIBLE))
    }

    // —— 等待自己说话（新腿要证明的正是"在外面待过"） ——

    @Test
    fun `the wait describes how many times it looked and how long it took`() {
        // 只回 true/false 的等待，在台账上把"待了 90 秒再回来"和"根本没等就成了"记成同一件事
        // ——判据看不见它要判的东西。runner 按这串做机械断言（reads>1、waited_ms 落区间）。
        val reached = ForegroundWaitTrace(
            reached = true, reads = 47, waitedMs = 91_300, lastPackage = "com.tencent.mm",
        )

        assertEquals("reads=47,waited_ms=91300,result=reached,last=com.tencent.mm", reached.describe())
    }

    @Test
    fun `a timed out wait says what it kept seeing instead`() {
        // 2026-08-02 debug hook 那次前台超时只知道"没等到"，不知道它一直看见的是什么，
        // 于是下一轮又得烧一次真机。
        val timeout = ForegroundWaitTrace(
            reached = false, reads = 100, waitedMs = 20_000, lastPackage = "com.android.launcher",
        )

        assertEquals("reads=100,waited_ms=20000,result=timeout,last=com.android.launcher", timeout.describe())
    }

    @Test
    fun `an unreadable foreground is a dash rather than an empty field`() {
        // 空字段在台账里读起来像"数据丢了"；显式写成 - 才分得清"读不出来"。
        val blind = ForegroundWaitTrace(reached = false, reads = 1, waitedMs = 0, lastPackage = "")

        assertTrue(blind.describe(), blind.describe().endsWith(",last=-"))
    }

    private companion object {
        val SHA_A = "aa".repeat(32)
        val SHA_B = "bb".repeat(32)
    }
}
