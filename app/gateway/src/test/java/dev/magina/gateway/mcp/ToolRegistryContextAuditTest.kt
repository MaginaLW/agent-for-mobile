package dev.magina.gateway.mcp

import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.GatewayError
import dev.magina.gateway.core.Level
import dev.magina.gateway.core.SafetyContext
import dev.magina.gateway.core.SafetyGate
import dev.magina.gateway.core.SafetyPolicy
import dev.magina.gateway.core.SafetyTarget
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class ToolRegistryContextAuditTest {
    private val initialContext = SafetyContext(
        packageName = "dev.magina.fixture",
        activityName = ".TargetActivity",
        revision = 7,
        target = SafetyTarget(ref = "r1", text = "发送", bounds = "[0,0][10,10]", source = "a11y"),
    )

    private fun args() = JSONObject().put("ref", "r1").put("action", "click")

    private fun scope() = ToolRegistry.CallScope("ui_action", SafetyPolicy.fingerprint(args()))

    @Test
    fun `first read captures initial approval scope without recheck marker`() {
        val call = scope()
        assertSame(initialContext, call.readContext {
            assertEquals(1, call.contextReads)
            assertFalse(call.safetyNote.contains("context=rechecked"))
            initialContext
        })

        assertTrue(call.staleKey.isNotEmpty())
        assertFalse(call.safetyNote.contains("context=rechecked"))
    }

    @Test
    fun `second successful read records marker before reader and preserves initial scope`() {
        val call = scope()
        call.readContext { initialContext }
        val initialKey = call.staleKey
        val changed = initialContext.copy(target = initialContext.target!!.copy(text = "删除"))

        assertSame(changed, call.readContext {
            assertEquals(2, call.contextReads)
            assertEquals(";context=rechecked", call.safetyNote)
            changed
        })

        assertEquals(initialKey, call.staleKey)
        assertEquals(";context=rechecked", call.safetyNote)
    }

    @Test
    fun `second failing read records marker before propagating identical reader error`() {
        val call = scope()
        call.readContext { initialContext }
        val initialKey = call.staleKey
        val failure = IllegalStateException("stale target")

        val actual = expectError<IllegalStateException> {
            call.readContext {
                assertEquals(2, call.contextReads)
                assertEquals(";context=rechecked", call.safetyNote)
                throw failure
            }
        }

        assertSame(failure, actual)
        assertEquals(initialKey, call.staleKey)
        assertEquals(";context=rechecked", call.safetyNote)
    }

    @Test
    fun `initial reader failure through gate has no recheck marker or execution`() {
        val call = scope()
        val failure = IllegalStateException("initial resolution failed")
        val gate = SafetyGate(
            policy = SafetyPolicy(),
            confirmer = { error("initial failure must precede confirmation") },
            contextProvider = { call.readContext { throw failure } },
            onExecutionFailure = { error("initial failure is not execution failure") },
            afterExecutionSuccess = { _, _ -> error("initial failure must not report success") },
        )

        val actual = expectError<IllegalStateException> {
            gate.execute("ui_action", Level.W, args()) { _, _ -> error("must not execute") }
        }

        assertSame(failure, actual)
        assertEquals(1, call.contextReads)
        assertEquals("", call.staleKey)
        assertFalse(call.safetyNote.contains("context=rechecked"))
    }

    @Test
    fun `gate converts recheck resolution failure to nonretryable safety stale without execution`() {
        val call = scope()
        var handlerCalls = 0
        var successCalls = 0
        var failureRecords = 0
        var staleCalls = 0
        val gate = SafetyGate(
            policy = SafetyPolicy(),
            confirmer = { true },
            contextProvider = {
                call.readContext {
                    if (call.contextReads > 1) {
                        assertEquals(";context=rechecked", call.safetyNote)
                        throw IllegalStateException("target disappeared")
                    }
                    initialContext
                }
            },
            onExecutionFailure = { failureRecords++ },
            afterExecutionSuccess = { _, _ -> successCalls++ },
            onStaleAfterApproval = { _, _ -> staleCalls++ },
        )

        val actual = expectError<GatewayError> {
            gate.execute("ui_action", Level.W, args()) { _, _ -> handlerCalls++ }
        }

        assertEquals(ErrorCode.E_STALE_REF, actual.code)
        assertEquals("safety", actual.channel)
        assertFalse(actual.retryable)
        assertEquals(2, call.contextReads)
        assertEquals(";context=rechecked", call.safetyNote)
        assertEquals(0, handlerCalls)
        assertEquals(0, successCalls)
        assertEquals(0, failureRecords)
        assertEquals(1, staleCalls)
    }

    @Test
    fun `allowed matching context still executes once and reports success`() {
        val call = scope()
        var handlerCalls = 0
        var successCalls = 0
        val gate = SafetyGate(
            policy = SafetyPolicy(),
            confirmer = { true },
            contextProvider = { call.readContext { initialContext } },
            onExecutionFailure = { error("success must not record failure") },
            afterExecutionSuccess = { _, _ -> successCalls++ },
        )

        val result = gate.execute("ui_action", Level.W, args()) { _, context ->
            assertSame(initialContext, context)
            assertEquals(";context=rechecked", call.safetyNote)
            handlerCalls++
            "executed"
        }

        assertEquals("executed", result)
        assertEquals(2, call.contextReads)
        assertEquals(1, handlerCalls)
        assertEquals(1, successCalls)
    }

    @Test
    fun `denied confirmation stops before recheck and has no marker`() {
        val actual = assertStoppedBeforeRecheck(confirm = { false })
        assertEquals(ErrorCode.E_BLOCKED, actual.code)
    }

    @Test
    fun `changed arguments stop before recheck and have no marker`() {
        val actual = assertStoppedBeforeRecheck(confirm = { original ->
            original.put("ref", "changed")
            true
        })
        assertEquals(ErrorCode.E_STALE_REF, actual.code)
    }

    @Test
    fun `after allowed failure stops before recheck and has no marker`() {
        val failure = GatewayError(ErrorCode.E_BLOCKED, "after allowed failed", channel = "safety")
        val actual = assertStoppedBeforeRecheck(confirm = { true }, afterAllowed = { throw failure })
        assertSame(failure, actual)
    }

    private fun assertStoppedBeforeRecheck(
        confirm: (JSONObject) -> Boolean,
        afterAllowed: () -> Unit = {},
    ): GatewayError {
        val call = scope()
        val original = args()
        val gate = SafetyGate(
            policy = SafetyPolicy(),
            confirmer = { confirm(original) },
            contextProvider = { call.readContext { initialContext } },
            onExecutionFailure = { error("pre-execution stop must not record failure") },
            afterConfirmationAllowed = { _, _, _ -> afterAllowed() },
            afterExecutionSuccess = { _, _ -> error("pre-execution stop must not report success") },
        )

        val actual = expectError<GatewayError> {
            gate.execute("ui_action", Level.W, original) { _, _ -> error("must not execute") }
        }

        assertEquals(1, call.contextReads)
        assertFalse(call.safetyNote.contains("context=rechecked"))
        return actual
    }

    @Test
    fun `exact nav fallback eligibility requires Allowed ordinary 4-plus char OCR click and rejects all protected or non-click actions`() {
        val policy = SafetyPolicy(sensitiveTargets = listOf("秘密会话"))
        val baseContext = SafetyContext(
            packageName = "com.tencent.mm",
            activityName = ".ui.LauncherUI",
            revision = 12,
            sameAppMultiWindow = true,
        )
        val clickArgs = JSONObject().put("ref", "o:abc:1:7").put("action", "click")

        // 正向：普通 >=4 字具名 OCR click 且 SafetyDecision.Allowed → 放行
        assertTrue(
            ToolRegistry.isExactNavFallbackEligible(
                policy = policy,
                action = "click",
                isOcrOnly = true,
                label = "文件传输助手",
                desc = "",
                bounds = "[216,282][498,326]",
                source = "ocr",
                windowPane = "left",
                baseContext = baseContext,
                args = clickArgs,
            ),
        )

        // 非 click（long_click / scroll / set_text）一律拒绝
        for (otherAction in listOf("long_click", "scroll", "set_text", "focus")) {
            val otherArgs = JSONObject().put("ref", "o:abc:1:7").put("action", otherAction)
            assertFalse(
                "action=$otherAction 不得启用 exact_nav",
                ToolRegistry.isExactNavFallbackEligible(
                    policy, otherAction, true, "文件传输助手", "", "[216,282][498,326]", "ocr", "left", baseContext, otherArgs,
                ),
            )
        }

        // 非纯 OCR ref（a11y/fused）一律拒绝
        assertFalse(
            ToolRegistry.isExactNavFallbackEligible(
                policy, "click", false, "文件传输助手", "", "[216,282][498,326]", "a11y", "left", baseContext, clickArgs,
            ),
        )

        // 短标签（<4 字）、纯图标（空标签）、危险/确认/发送/敏感目标一律拒绝
        for (blockedLabel in listOf("", "返回", "123", "发送", "删除", "支付", "确认", "确认发送", "立即支付", "删除聊天", "秘密会话")) {
            assertFalse(
                "label=「$blockedLabel」不得启用 exact_nav",
                ToolRegistry.isExactNavFallbackEligible(
                    policy, "click", true, blockedLabel, "", "[216,282][498,326]", "ocr", "left", baseContext, clickArgs,
                ),
            )
        }
    }

    @Test
    fun `post-resolve exact_nav recheck blocks any non-Allowed target and audit note appends idempotently`() {
        val policy = SafetyPolicy(sensitiveTargets = listOf("秘密会话"))
        val baseContext = SafetyContext(
            packageName = "com.tencent.mm",
            activityName = ".ui.LauncherUI",
            revision = 12,
            sameAppMultiWindow = true,
        )
        val clickArgs = JSONObject().put("ref", "o:abc:1:7").put("action", "click")

        // 复核后仍为普通具名点击 → 通过
        ToolRegistry.requireExactNavStillAllowed(
            policy,
            clickArgs,
            baseContext.copy(target = SafetyTarget(ref = "o:abc:1:7", text = "文件传输助手", bounds = "[216,282][498,326]", source = "ocr", windowPane = "left")),
        )

        // 复核后落成确认/危险/敏感/空白目标 → fail-closed 抛 E_BLOCKED
        for (badText in listOf("确认发送", "删除聊天", "秘密会话", "")) {
            val err = expectError<GatewayError> {
                ToolRegistry.requireExactNavStillAllowed(
                    policy,
                    clickArgs,
                    baseContext.copy(target = SafetyTarget(ref = "o:abc:1:7", text = badText, bounds = "[216,282][498,326]", source = "ocr", windowPane = "left")),
                )
            }
            assertEquals(ErrorCode.E_BLOCKED, err.code)
            assertEquals("safety", err.channel)
        }

        // 审计 note 标记幂等且格式干净
        val call = scope()
        call.appendSafetyNote(ToolRegistry.OCR_REVERIFY_EXACT_NAV_NOTE)
        assertEquals("ocr_reverify=exact_nav", call.safetyNote)
        call.appendSafetyNote(ToolRegistry.OCR_REVERIFY_EXACT_NAV_NOTE)
        assertEquals("ocr_reverify=exact_nav", call.safetyNote)
    }

    @Test
    fun `context read phase helpers distinguish initial read from post-confirm recheck`() {
        val call = scope()
        assertFalse(isInitialContextRead(call.contextReads))
        assertFalse(isRecheckContextRead(call.contextReads))

        call.readContext {
            assertTrue(isInitialContextRead(call.contextReads))
            assertFalse(isRecheckContextRead(call.contextReads))
            initialContext
        }

        call.readContext {
            assertFalse(isInitialContextRead(call.contextReads))
            assertTrue(isRecheckContextRead(call.contextReads))
            initialContext
        }
    }

    private inline fun <reified T : Throwable> expectError(block: () -> Unit): T {
        try {
            block()
        } catch (actual: Throwable) {
            if (actual is T) return actual
            throw actual
        }
        error("expected ${T::class.java.simpleName}")
    }
}
