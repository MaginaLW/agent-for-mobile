package dev.magina.gateway.testing

import dev.magina.gateway.core.ApprovalChannel
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
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/** JVM doubles prove the original gate boundary; they do not prove Android approval or callbacks. */
class TestTargetStaleControlTest {
    @get:Rule
    val temp = TemporaryFolder()

    private val now = 1_000_000L
    private val targetPackage = "dev.magina.testtarget"
    private val attempt = TestConfirmationAttempt(
        confirmationId = "abc123def456",
        toolName = "ui_action",
        action = "click",
        initialPackage = targetPackage,
    )

    @Test
    fun `owned click stays inactive without a control file`() {
        var captures = 0
        val session = control().onConfirmationShown(attempt) {
            captures++
            capture()
        }

        assertFalse(session.armed)
        assertEquals(0, captures)
    }

    @Test
    fun `owned click accepts only the exact stale tuple without Enter input digest`() {
        writeCommand()
        val control = control()
        val session = control.onConfirmationShown(attempt, ::capture)
        val state = JSONObject(File(temp.root, DebugTestControl.STATE_FILE_NAME).readText())

        assertTrue(session.armed)
        assertEquals(attempt.confirmationId, state.getString("confirm_id"))
        assertEquals("owned-stale-run-01", state.getString("run_id"))
        assertEquals("owned-stale-nonce-01", state.getString("nonce"))
        assertEquals("stale", state.getString("leg"))
        assertEquals("ui_action", state.getString("tool"))
        assertEquals("click", state.getString("action"))
        assertEquals(targetPackage, state.getString("initial_package"))
        assertEquals("evidence_ready", state.getString("state"))
        assertTrue(state.getBoolean("card_visible"))
        assertFalse(state.has("decided_via"))
        assertTrue(File(temp.root, "confirmation-${attempt.confirmationId}.png").isFile)

        // Recreating the instruction cannot replay this nonce, even before a decision.
        writeCommand()
        expectError(ErrorCode.E_BLOCKED) { control.onConfirmationShown(attempt, ::capture) }
    }

    @Test
    fun `owned control rejects other legs packages tools actions and expired commands before capture`() {
        val cases = listOf(
            command().put("leg", "allow").put("stale_after_allow", false),
            command().put("leg", "deny").put("stale_after_allow", false),
            command().put("initial_package", "com.example.other"),
            command().put("initial_package", "com.tencent.mm"),
            command().put("tool", "press_key").put("action", "enter"),
            command().put("action", "long_click"),
            command().put("stale_after_allow", false),
            command().put("expires_at_ms", now),
            command().put("expires_at_ms", now + 300_001),
            command().put("decision", "allowed"),
            command().put("ref", "r1"),
        )
        cases.forEachIndexed { index, json ->
            File(temp.root, DebugTestControl.CONTROL_FILE_NAME).writeText(json.toString())
            var captures = 0
            expectError(ErrorCode.E_BLOCKED) {
                control().onConfirmationShown(attempt) { captures++; capture() }
            }
            assertEquals("case $index", 0, captures)
        }
    }

    @Test
    fun `owned control requires matching attempt and confirmation id before Home`() {
        writeCommand()
        val control = control()
        val session = control.onConfirmationShown(attempt, ::capture)
        control.onConfirmationDecision(session, TestConfirmationDecision.ALLOWED, ApprovalChannel.OVERLAY)
        var homes = 0

        expectError(ErrorCode.E_BLOCKED) {
            control.afterAllowed(session, attempt.copy(confirmationId = "000000000000"), { homes++; true }) {
                TestForeground(true, "launcher")
            }
        }

        assertEquals(0, homes)
    }

    @Test
    fun `owned control never homes without one observed allowed decision`() {
        listOf(null, TestConfirmationDecision.DENIED, TestConfirmationDecision.TIMED_OUT).forEachIndexed { index, decision ->
            writeCommand(nonce = "owned-not-allowed-$index")
            val control = control()
            val session = control.onConfirmationShown(attempt, ::capture)
            decision?.let { control.onConfirmationDecision(session, it, ApprovalChannel.OVERLAY) }
            var homes = 0

            expectError(ErrorCode.E_BLOCKED) {
                control.afterAllowed(session, attempt, { homes++; true }) { TestForeground(true, "launcher") }
            }
            assertEquals(0, homes)
        }
    }

    @Test
    fun `owned stale injection waits for non target and original gate rejects before handler or success callback`() {
        writeCommand()
        val control = control()
        val initial = SafetyContext(
            packageName = targetPackage,
            activityName = ".MainActivity",
            revision = 1,
            target = SafetyTarget(ref = "r1", text = "发送", bounds = "[1,2][3,4]", source = "a11y"),
        )
        var context = initial
        var homes = 0
        var foregroundReads = 0
        var contextReads = 0
        var handlerCalls = 0
        var successCallbacks = 0
        var failureCallbacks = 0
        var staleCallbacks = 0
        var session: TestControlSession = InactiveTestControlSession
        val gate = SafetyGate(
            policy = SafetyPolicy(),
            confirmer = { decision ->
                assertEquals(attempt.toolName, decision.toolName)
                assertEquals(attempt.action, decision.action)
                assertEquals(attempt.initialPackage, decision.initialPackage)
                session = control.onConfirmationShown(attempt, ::capture)
                // Simulated observed decision for JVM only; Android must use the visible real card.
                control.onConfirmationDecision(session, TestConfirmationDecision.ALLOWED, ApprovalChannel.OVERLAY)
                true
            },
            contextProvider = { contextReads++; context },
            onExecutionFailure = { failureCallbacks++ },
            afterConfirmationAllowed = { _, _, _ ->
                control.afterAllowed(session, attempt, performHome = { homes++; true }) {
                    foregroundReads++
                    when (foregroundReads) {
                        1 -> TestForeground(false, "")
                        2 -> TestForeground(true, targetPackage)
                        else -> {
                            context = initial.copy(packageName = "launcher", activityName = ".Home", revision = 2)
                            TestForeground(true, "launcher")
                        }
                    }
                }
            },
            afterExecutionSuccess = { _, _ -> successCallbacks++ },
            onStaleAfterApproval = { _, _ -> staleCallbacks++ },
        )

        expectError(ErrorCode.E_STALE_REF) {
            gate.execute("ui_action", Level.W, JSONObject().put("ref", "r1").put("action", "click")) { _, _ ->
                handlerCalls++
            }
        }
        assertEquals(1, homes)
        assertEquals(3, foregroundReads)
        assertEquals(2, contextReads)
        assertEquals(0, handlerCalls)
        assertEquals(0, successCallbacks)
        assertEquals(0, failureCallbacks)
        assertEquals(1, staleCallbacks)
        val state = JSONObject(File(temp.root, DebugTestControl.STATE_FILE_NAME).readText())
        assertEquals("allowed", state.getString("state"))
        assertEquals("overlay", state.getString("decided_via"))
        assertEquals(attempt.confirmationId, state.getString("confirm_id"))

        expectError(ErrorCode.E_BLOCKED) {
            control.afterAllowed(session, attempt, { homes++; true }) { TestForeground(true, "launcher") }
        }
        assertEquals(1, homes)
    }

    @Test
    fun `owned target remaining foreground is channel failure rather than fake stale`() {
        writeCommand()
        var monotonic = 0L
        val control = DebugTestControl(
            filesDir = temp.root, cacheDir = temp.root, clock = { now },
            monotonicClock = { monotonic }, sleep = { monotonic += it }, foregroundTimeoutMs = 100,
        )
        val session = control.onConfirmationShown(attempt, ::capture)
        control.onConfirmationDecision(session, TestConfirmationDecision.ALLOWED, ApprovalChannel.OVERLAY)
        var homes = 0

        expectError(ErrorCode.E_CHANNEL_DOWN) {
            control.afterAllowed(session, attempt, { homes++; true }) { TestForeground(true, targetPackage) }
        }
        assertEquals(1, homes)
        assertEquals(100L, monotonic)
    }

    private fun control() = DebugTestControl(
        filesDir = temp.root, cacheDir = temp.root, clock = { now }, monotonicClock = { now }, sleep = {},
    )

    private fun capture() = TestConfirmationCapture(byteArrayOf(1), cardVisible = true, attempts = 1)

    private fun command(nonce: String = "owned-stale-nonce-01") = JSONObject()
        .put("run_id", "owned-stale-run-01").put("leg", "stale").put("nonce", nonce)
        .put("expires_at_ms", now + 60_000).put("tool", "ui_action").put("action", "click")
        .put("initial_package", targetPackage).put("stale_after_allow", true)

    private fun writeCommand(nonce: String = "owned-stale-nonce-01") {
        File(temp.root, DebugTestControl.CONTROL_FILE_NAME).writeText(command(nonce).toString())
    }

    private fun expectError(code: ErrorCode, block: () -> Unit) {
        try {
            block()
            fail("expected $code")
        } catch (error: GatewayError) {
            assertEquals(code, error.code)
        }
    }
}
