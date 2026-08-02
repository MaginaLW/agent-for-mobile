package dev.magina.gateway.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * 语义意图路径的门级用例（spec §5 第 3、5 条）。
 *
 * 机械证据的形态与既有那条 `confirmerCalls == 0` 完全一样：**失败时 executor 调用次数必须为 0**
 * ——"没执行"这件事不能靠读代码相信，要有一个数字说话。
 */
class SafetyGateIntentPathTest {

    private val imeSessionId = "ime|0123456789abcdef01234567"
    private val nodeId =
        "7|com.tencent.mm:id/chat_input|android.widget.EditText|com.tencent.mm|10,20,100,80"
    private val identity = FocusIdentity(IdentitySource.A11Y, nodeId, imeSessionId)
    private val text = "P0ALLOW-3479AHKMPT"
    private val args = JSONObject().put("key", "enter")

    private fun context(
        packageName: String = "com.tencent.mm",
        label: String = "文件传输助手",
    ) = SafetyContext(
        packageName = packageName,
        activityName = "com.tencent.mm/.ui.LauncherUI",
        revision = 1,
        target = SafetyTarget(
            focusIdentity = identity,
            focusedInputBounds = "[10,20][100,80]",
            inputCommitEvidence = InputCommitEvidence(
                commitId = 1,
                preview = text,
                length = text.length,
                sha256 = InputCommitEvidence.sha256(text),
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

    private class Harness(
        confirmed: Boolean = true,
        val contexts: MutableList<SafetyContext>,
        awaitForeground: (String, Long) -> Boolean = { _, _ -> true },
        clock: () -> Long = { 1_000 },
        rebuildEvidence: ((ApprovalIntent) -> EvidenceRebuild)? = null,
    ) {
        var executorCalls = 0
        var confirmerCalls = 0
        var rebuildCalls = 0
        val store = IntentApprovalStore()
        private var reads = 0

        val gate = SafetyGate(
            policy = SafetyPolicy(),
            confirmer = { confirmerCalls += 1; confirmed },
            contextProvider = { contexts[minOf(reads++, contexts.size - 1)] },
            onExecutionFailure = {},
            intentApproval = IntentApproval(
                intentIdFactory = { "intent-fixed" },
                awaitForeground = awaitForeground,
                store = store,
                clock = clock,
                rebuildEvidence = rebuild@{ intent ->
                    rebuildCalls += 1
                    val supplied = rebuildEvidence ?: return@rebuild EvidenceRebuild.Unverified("未装配")
                    supplied(intent)
                },
            ),
        )

        fun press(args: JSONObject): Result<String> = runCatching {
            gate.execute("press_key", Level.W, args) { _, _ -> executorCalls += 1; "sent" }
        }
    }

    private fun assertTerminal(result: Result<String>, code: ErrorCode, expectIn: String) {
        val error = result.exceptionOrNull() as? GatewayError ?: fail("期望 GatewayError，实际 $result") as Nothing
        assertEquals(code, error.code)
        assertTrue("原因未点名：${error.message}", error.message.orEmpty().contains(expectIn))
    }

    @Test
    fun `semantic intent lets a moved focus through as long as the meaning is unchanged`() {
        // 收益就在这一条：批准之后 IME 会话重建、几何变了，而"往文件传输助手发这条消息"没变。
        val other = FocusIdentity(IdentitySource.A11Y, nodeId.replace("chat_input", "other"), imeSessionId)
        val after = context().let { base ->
            base.copy(
                target = base.target!!.copy(
                    focusIdentity = other,
                    focusedInputBounds = "[11,21][101,81]",
                    inputCommitEvidence = base.target!!.inputCommitEvidence!!.copy(identity = other),
                    preparedTargetEvidence = base.target!!.preparedTargetEvidence!!.copy(
                        identity = other,
                        bounds = "[11,21][101,81]",
                    ),
                ),
            )
        }
        val harness = Harness(contexts = mutableListOf(context(), after))

        val result = harness.press(args)

        assertEquals("sent", result.getOrNull())
        assertEquals(1, harness.executorCalls)
    }

    @Test
    fun `foreground wait timeout is terminal and never executes`() {
        val harness = Harness(
            contexts = mutableListOf(context(), context()),
            awaitForeground = { _, _ -> false },
        )

        val result = harness.press(args)

        assertTerminal(result, ErrorCode.E_STALE_REF, "等前台恢复")
        assertEquals("批准了却没执行——这个 0 就是机械证据", 0, harness.executorCalls)
    }

    @Test
    fun `intent mismatch after approval is terminal and never executes`() {
        val harness = Harness(contexts = mutableListOf(context(), context(label = "张三")))

        val result = harness.press(args)

        assertTerminal(result, ErrorCode.E_STALE_REF, "目标会话与意图不符")
        assertEquals(0, harness.executorCalls)
    }

    @Test
    fun `denied confirmation executes nothing and leaves no intent behind`() {
        // 档位差异不改变这一条：任一档位、未获批准时执行次数仍为 0，且不留下可用的意图。
        val harness = Harness(confirmed = false, contexts = mutableListOf(context(), context()))

        val result = harness.press(args)

        assertTerminal(result, ErrorCode.E_BLOCKED, "用户拒绝")
        assertEquals(0, harness.executorCalls)
        assertEquals(1, harness.confirmerCalls)
        assertTrue("拒绝之后不该有待用意图", !harness.store.isPending)
    }

    @Test
    fun `intent is consumed before execution so a failed run cannot reuse it`() {
        // 「意图不因执行失败而复活」的机械证据：executor 抛错之后，保管处必须是空的。
        val harness = Harness(contexts = mutableListOf(context(), context()))

        val result = runCatching {
            harness.gate.execute("press_key", Level.W, args) { _, _ ->
                harness.executorCalls += 1
                throw GatewayError(ErrorCode.E_VERIFY_FAIL, "发送后验失败")
            }
        }

        assertTrue(result.isFailure)
        assertEquals(1, harness.executorCalls)
        assertTrue("执行失败后意图必须已经销毁", !harness.store.isPending)
    }

    @Test
    fun `expired intent cannot be executed even when everything else matches`() {
        var now = 1_000L
        val harness = Harness(
            contexts = mutableListOf(context(), context()),
            clock = { now },
            awaitForeground = { _, _ -> now += 200_000; true },
        )

        val result = harness.press(args)

        assertTerminal(result, ErrorCode.E_STALE_REF, "意图已过期")
        assertEquals(0, harness.executorCalls)
    }

    @Test
    fun `broken evidence chain at execution time blocks the enter`() {
        // 意图匹配过了，但这一刻的证据链自己不自洽（三处身份对不上）——照旧拒绝。
        val broken = context().let { base ->
            base.copy(
                target = base.target!!.copy(
                    focusIdentity = FocusIdentity(
                        IdentitySource.A11Y,
                        nodeId.replace("chat_input", "other"),
                        imeSessionId,
                    ),
                ),
            )
        }
        val harness = Harness(contexts = mutableListOf(context(), broken))

        val result = harness.press(args)

        assertTerminal(result, ErrorCode.E_BLOCKED, "证据链不自洽")
        assertEquals(0, harness.executorCalls)
    }

    @Test
    fun `irreversible tier never enters the wait`() {
        // I 级批准与执行紧挨着：预算为 0，等待回调一次都不该被叫到。
        var waits = 0
        val clicking = JSONObject().put("action", "click")
        val target = context().target!!.copy(text = "确认交易")
        val ctx = context().copy(target = target)
        val harness = Harness(
            contexts = mutableListOf(ctx, ctx),
            awaitForeground = { _, _ -> waits += 1; true },
        )

        harness.gate.execute("ui_action", Level.W, clicking) { _, _ -> harness.executorCalls += 1; "clicked" }

        assertEquals("I 级不进等待", 0, waits)
        assertEquals(1, harness.executorCalls)
    }

    // —— 选项 C：批准后重建证据（走开再回来那条腿的全部依据） ——

    /** 切走再回来之后的现场：身份换了，旧输入证据按身份取不出来，于是这一项为 null。 */
    private fun afterReentry() = context().let { base ->
        val newIdentity = FocusIdentity(IdentitySource.A11Y, nodeId.replace("chat_input", "reentry"), imeSessionId)
        base.copy(
            target = base.target!!.copy(
                focusIdentity = newIdentity,
                inputCommitEvidence = null,
                preparedTargetEvidence = base.target!!.preparedTargetEvidence!!.copy(identity = newIdentity),
            ),
        )
    }

    /** 重建成功之后的现场：证据按**当前**身份重新落进证据仓。 */
    private fun afterRebuild() = afterReentry().let { base ->
        val identity = base.target!!.focusIdentity!!
        base.copy(
            target = base.target!!.copy(
                inputCommitEvidence = InputCommitEvidence(
                    commitId = 2,
                    preview = text,
                    length = text.length,
                    sha256 = InputCommitEvidence.sha256(text),
                    identity = identity,
                    readbackVerified = true,
                    committedAtMs = 1_000,
                    expiresAtMs = 121_000,
                ),
            ),
        )
    }

    @Test
    fun `rebuild is skipped entirely when the evidence survived`() {
        // 人慢但没离开输入会话：证据还在，重建一步都不该走——它是恢复步骤，不是例行步骤。
        val harness = Harness(contexts = mutableListOf(context(), context()))

        harness.press(args)

        assertEquals(0, harness.rebuildCalls)
        assertEquals(1, harness.executorCalls)
    }

    @Test
    fun `rebuilt evidence lets the re-entry leg through`() {
        // 这一条就是"批准后切走再回来"能成立的全部依据。
        val harness = Harness(
            contexts = mutableListOf(context(), afterReentry(), afterRebuild()),
            rebuildEvidence = { EvidenceRebuild.Rebuilt(InputCommitEvidence.sha256(text), text.length) },
        )

        val result = harness.press(args)

        assertEquals("sent", result.getOrNull())
        assertEquals(1, harness.rebuildCalls)
        assertEquals(1, harness.executorCalls)
    }

    @Test
    fun `rebuild mismatch is terminal and never executes`() {
        val harness = Harness(
            contexts = mutableListOf(context(), afterReentry(), afterReentry()),
            rebuildEvidence = { EvidenceRebuild.Mismatch("内容摘要与已批准的不符：aaa → bbb") },
        )

        val result = harness.press(args)

        assertTerminal(result, ErrorCode.E_STALE_REF, "重建输入证据与已批准的意图不符")
        assertEquals(0, harness.executorCalls)
    }

    @Test
    fun `rebuild unverified gets its own error code and never executes`() {
        // 判不了 ≠ 不匹配：两者都不放行，但台账上必须分得开，否则下一轮只能靠猜。
        val harness = Harness(
            contexts = mutableListOf(context(), afterReentry(), afterReentry()),
            rebuildEvidence = { EvidenceRebuild.Unverified("读回内容为空，判不了（channel=ocr）") },
        )

        val result = harness.press(args)

        assertTerminal(result, ErrorCode.E_VERIFY_FAIL, "判不了")
        assertEquals(0, harness.executorCalls)
    }

    @Test
    fun `unwired rebuild fails closed instead of passing`() {
        // 没装配重建通道 = 重建不了。绝不因为"没实现"而放行。
        val harness = Harness(contexts = mutableListOf(context(), afterReentry(), afterReentry()))

        val result = harness.press(args)

        assertTerminal(result, ErrorCode.E_VERIFY_FAIL, "判不了")
        assertEquals(0, harness.executorCalls)
    }

    @Test
    fun `rebuild does not resurrect the approval`() {
        // 重建的是**证据**，不是**批准**：一次性、消费在执行之前这两条不许被绕开。
        val harness = Harness(
            contexts = mutableListOf(context(), afterReentry(), afterRebuild()),
            rebuildEvidence = { EvidenceRebuild.Rebuilt(InputCommitEvidence.sha256(text), text.length) },
        )

        harness.press(args)

        assertTrue("执行后不得留下可用意图", !harness.store.isPending)
        // 第二次调用必须重新走人的确认；这里直接验"意图没被重建续命"。
        assertEquals(1, harness.confirmerCalls)
    }

    @Test
    fun `rebuild cannot rescue an expired intent`() {
        // 重建证据不延长任何时钟：意图过期就是过期。
        var now = 1_000L
        val harness = Harness(
            contexts = mutableListOf(context(), afterReentry(), afterRebuild()),
            clock = { now },
            awaitForeground = { _, _ -> now += 200_000; true },
            rebuildEvidence = { EvidenceRebuild.Rebuilt(InputCommitEvidence.sha256(text), text.length) },
        )

        val result = harness.press(args)

        assertTerminal(result, ErrorCode.E_STALE_REF, "意图已过期")
        assertEquals(0, harness.executorCalls)
    }

    @Test
    fun `retractable tier does enter the wait`() {
        var waits = 0
        val harness = Harness(
            contexts = mutableListOf(context(), context()),
            awaitForeground = { pkg, budget ->
                waits += 1
                assertEquals("com.tencent.mm", pkg)
                assertEquals(IntentApprovalClocks.DEFAULT_FOREGROUND_WAIT_BUDGET_MS, budget)
                true
            },
        )

        harness.press(args)

        assertEquals(1, waits)
    }
}
