package dev.magina.gateway.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 语义意图审批 spec §2.3 判据对照表的逐行用例。
 *
 * **表里每一行都要有正例和反例**：只写正例的话，"某一行根本没被实现"和"实现了且通过"
 * 在断言上长得一模一样——这正是本项目反复付学费的那种覆盖假象。
 * 刻意**不比**的三行（activityName / identityBootstrapped / 跨时间 focusIdentity 与 bounds）
 * 同样要有用例：它们的"正确行为"是**变了也仍然匹配**，没有用例钉住的话，
 * 将来有人顺手把它们加回去就没人拦得住，而那是安全姿态变更、要回 B 道。
 */
class ApprovalIntentMatchTest {

    private val imeSessionId = "ime|0123456789abcdef01234567"
    private val nodeId =
        "7|com.tencent.mm:id/chat_input|android.widget.EditText|com.tencent.mm|10,20,100,80"
    private val strict = FocusIdentity(IdentitySource.A11Y, nodeId, imeSessionId)
    private val text = "晚点到，先别等我"

    private fun input(
        body: String = text,
        expiresAtMs: Long = 61_000,
        identity: FocusIdentity = strict,
    ) = InputCommitEvidence(
        commitId = 7,
        preview = body,
        length = body.length,
        sha256 = InputCommitEvidence.sha256(body),
        identity = identity,
        readbackVerified = true,
        committedAtMs = 1_000,
        expiresAtMs = expiresAtMs,
    )

    private fun prepared(
        label: String = "文件传输助手",
        packageName: String = "com.tencent.mm",
        expiresAtMs: Long = 61_000,
        bounds: String? = "[10,20][100,80]",
    ) = PreparedTargetEvidence(
        preparedId = 3,
        label = label,
        packageName = packageName,
        identity = strict,
        bounds = bounds,
        preparedAtMs = 1_000,
        expiresAtMs = expiresAtMs,
    )

    private fun context(
        packageName: String = "com.tencent.mm",
        activityName: String = ".ui.LauncherUI",
        identityBootstrapped: Boolean = false,
        inputEvidence: InputCommitEvidence? = input(),
        preparedEvidence: PreparedTargetEvidence? = prepared(),
        focusedInputBounds: String? = "[10,20][100,80]",
    ) = SafetyContext(
        packageName = packageName,
        activityName = activityName,
        revision = 42,
        foregroundKnown = true,
        identityBootstrapped = identityBootstrapped,
        target = SafetyTarget(
            focusIdentity = strict,
            focusedInputBounds = focusedInputBounds,
            inputCommitEvidence = inputEvidence,
            preparedTargetEvidence = preparedEvidence,
        ),
    )

    private val intent = ApprovalIntent(
        intentId = "intent-1",
        riskTier = RiskTier.RETRACTABLE,
        actionKind = "发送消息",
        targetPackage = "com.tencent.mm",
        targetLabel = "文件传输助手",
        contentSha256 = InputCommitEvidence.sha256(text),
        contentLength = text.length,
        preview = text,
        createdAtMs = 1_000,
        approvedAtMs = 2_000,
    )

    private fun match(
        ctx: SafetyContext = context(),
        nowMs: Long = 10_000,
        requiresTargetSession: Boolean = true,
    ) = IntentMatchPolicy.matches(intent, ctx, nowMs, requiresTargetSession)

    private fun rejectionOf(m: IntentMatch): String =
        (m as? IntentMatch.Rejected)?.reason ?: error("期望被拒，实际是 $m")

    // ---------- 基线 ----------

    @Test
    fun `全部对齐时匹配`() {
        assertEquals(IntentMatch.Matched, match())
    }

    // ---------- 行：packageName 硬相等 ----------

    @Test
    fun `前台包与意图不符时拒绝`() {
        val m = match(context(packageName = "com.vivo.hiboard"))

        assertTrue(rejectionOf(m).contains("前台包"))
    }

    // ---------- 行：activityName 不比（更弱，用户 08-02 接受） ----------

    @Test
    fun `activityName 变了仍然匹配`() {
        assertEquals(IntentMatch.Matched, match(context(activityName = ".ui.chatting.ChattingUI")))
        assertEquals(IntentMatch.Matched, match(context(activityName = "")))
    }

    // ---------- 行：identityBootstrapped 不比（更弱，用户 08-02 接受） ----------

    @Test
    fun `身份来源自举与否都不参与匹配`() {
        assertEquals(IntentMatch.Matched, match(context(identityBootstrapped = true)))
        assertEquals(IntentMatch.Matched, match(context(identityBootstrapped = false)))
    }

    // ---------- 行：focusIdentity / bounds 不做跨时间比较（侧移） ----------

    @Test
    fun `焦点几何变了仍然匹配`() {
        // 批准那一刻的 bounds 压根不在意图里，所以"变了"在这里是无从谈起的——
        // 这条用例钉的就是它确实没被偷偷塞进判据。
        assertEquals(IntentMatch.Matched, match(context(focusedInputBounds = "[0,0][9,9]")))
        assertEquals(IntentMatch.Matched, match(context(focusedInputBounds = null)))
    }

    // ---------- 行：内容 sha256 + length ----------

    @Test
    fun `内容改过时拒绝`() {
        val m = match(context(inputEvidence = input(body = "晚点到，先别等我了")))

        assertTrue(rejectionOf(m).contains("内容"))
    }

    @Test
    fun `没有输入证据时拒绝`() {
        val m = match(context(inputEvidence = null))

        assertTrue(rejectionOf(m).contains("输入提交证据"))
    }

    // ---------- 行：证据必须未过期（意图有效期放宽，证据 TTL 一字未放宽） ----------

    @Test
    fun `输入证据过期时拒绝`() {
        val m = match(context(inputEvidence = input(expiresAtMs = 5_000)), nowMs = 5_000)

        assertTrue(rejectionOf(m).contains("过期"))
    }

    @Test
    fun `输入证据恰好未到期时仍匹配`() {
        assertEquals(
            IntentMatch.Matched,
            match(context(inputEvidence = input(expiresAtMs = 5_001)), nowMs = 5_000),
        )
    }

    // ---------- 行：preparedTargetEvidence 的 label + package + 未过期 ----------

    @Test
    fun `目标会话名与意图不符时拒绝`() {
        val m = match(context(preparedEvidence = prepared(label = "张三")))

        assertTrue(rejectionOf(m).contains("目标会话"))
    }

    @Test
    fun `目标会话证据的包与意图不符时拒绝`() {
        val m = match(context(preparedEvidence = prepared(packageName = "com.xingin.xhs")))

        assertTrue(rejectionOf(m).contains("包"))
    }

    @Test
    fun `目标会话证据过期时拒绝`() {
        val m = match(context(preparedEvidence = prepared(expiresAtMs = 5_000)), nowMs = 5_000)

        assertTrue(rejectionOf(m).contains("过期"))
    }

    @Test
    fun `要求目标会话但证据缺失时拒绝`() {
        val m = match(context(preparedEvidence = null))

        assertTrue(rejectionOf(m).contains("目标会话证据"))
    }

    // ---------- spec §2.5：按档位收窄（B 道 2026-09-02 拍板） ----------

    @Test
    fun `不要求目标会话的动作类缺证据也匹配`() {
        // I 级 ui_action 没有会话可言，要求它等于逼实现造一个合成会话。
        assertEquals(
            IntentMatch.Matched,
            match(context(preparedEvidence = null), requiresTargetSession = false),
        )
    }

    @Test
    fun `不要求目标会话时也不因会话名不符而拒绝`() {
        assertEquals(
            IntentMatch.Matched,
            match(context(preparedEvidence = prepared(label = "张三")), requiresTargetSession = false),
        )
    }

    @Test
    fun `按档位收窄不放宽内容判据`() {
        // 收窄的是"要不要目标会话"，不是"内容还比不比"。
        val m = match(
            context(inputEvidence = input(body = "改过的内容"), preparedEvidence = null),
            requiresTargetSession = false,
        )

        assertTrue(rejectionOf(m).contains("内容"))
    }

    // ---------- 三个时钟必须分开（spec §2.4） ----------

    @Test
    fun `未获批的意图一律不算存活`() {
        // 没有批准就没有有效期可谈；createdAtMs 再新也不行。
        assertFalse(
            IntentMatchPolicy.isIntentLive(
                intent.copy(approvedAtMs = null), nowMs = 1_001, intentTtlMs = 360_000,
            ),
        )
    }

    @Test
    fun `intentTtl 从 approvedAtMs 起算而不是 createdAtMs`() {
        val ttl = 10_000L
        // createdAtMs=1000、approvedAtMs=2000。若误从 createdAtMs 起算，11_500 已超时；
        // 正确实现从 approvedAtMs 起算，此刻仍存活。
        assertTrue(IntentMatchPolicy.isIntentLive(intent, nowMs = 11_500, intentTtlMs = ttl))
        assertFalse(IntentMatchPolicy.isIntentLive(intent, nowMs = 12_000, intentTtlMs = ttl))
    }

    @Test
    fun `意图存活与证据匹配是两件事`() {
        // 意图还活着，但证据过期了 —— 仍必须拒绝执行。
        assertTrue(IntentMatchPolicy.isIntentLive(intent, nowMs = 5_000, intentTtlMs = 360_000))
        assertTrue(
            rejectionOf(match(context(inputEvidence = input(expiresAtMs = 5_000)), nowMs = 5_000))
                .contains("过期"),
        )
    }
}
