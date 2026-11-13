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
