package dev.magina.gateway.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SafetyPolicyTest {
    private val policy = SafetyPolicy()
    private val normalContext = SafetyContext(
        packageName = "com.tencent.mm",
        activityName = ".ui.LauncherUI",
        revision = 42,
    )

    @Test
    fun `Level D always requires confirmation`() {
        val decision = policy.assess(
            toolName = "future_dangerous_tool",
            level = Level.D,
            args = JSONObject(),
            context = normalContext,
        )

        assertTrue(decision is SafetyDecision.ConfirmationRequired)
    }

    @Test
    fun `ordinary read and write tools are allowed by default`() {
        val read = policy.assess("device_info", Level.R, JSONObject(), normalContext)
        val write = policy.assess(
            "type_text",
            Level.W,
            JSONObject().put("text", "只输入，不发送"),
            normalContext,
        )

        assertTrue(read is SafetyDecision.Allowed)
        assertTrue(write is SafetyDecision.Allowed)
    }

    @Test
    fun `press enter requires confirmation while navigation and delete keys are allowed`() {
        val enter = policy.assess(
            "press_key",
            Level.W,
            JSONObject().put("key", "enter"),
            normalContext.copy(target = SafetyTarget(focusedInputId = "chat-input")),
        )

        assertTrue(enter is SafetyDecision.ConfirmationRequired)
        listOf("back", "home", "del").forEach { key ->
            val decision = policy.assess(
                "press_key",
                Level.W,
                JSONObject().put("key", key),
                normalContext,
            )
            assertTrue("press_key($key) 不应升级为危险动作", decision is SafetyDecision.Allowed)
        }
    }

    @Test
    fun `dangerous ui targets require confirmation`() {
        listOf("发送", "删除联系人", "立即支付").forEach { targetText ->
            val decision = policy.assess(
                "ui_action",
                Level.W,
                JSONObject().put("ref", "r1").put("action", "click"),
                normalContext.copy(
                    target = SafetyTarget(
                        ref = "r1",
                        text = targetText,
                        bounds = "[1,2][30,40]",
                        source = "a11y",
                    ),
                ),
            )

            assertTrue("目标“$targetText”必须确认", decision is SafetyDecision.ConfirmationRequired)
        }
    }

    @Test
    fun `file transfer assistant context never exempts send`() {
        val decision = policy.assess(
            "ui_action",
            Level.W,
            JSONObject().put("ref", "send-button").put("action", "click"),
            normalContext.copy(
                target = SafetyTarget(
                    ref = "send-button",
                    text = "发送",
                    description = "发送给文件传输助手",
                    bounds = "[900,1800][1080,1920]",
                    source = "a11y",
                ),
            ),
        )

        assertTrue(decision is SafetyDecision.ConfirmationRequired)
    }

    @Test
    fun `dangerous long click target also requires confirmation`() {
        val decision = policy.assess(
            "ui_action",
            Level.W,
            JSONObject().put("ref", "delete-button").put("action", "long_click"),
            normalContext.copy(
                target = SafetyTarget(
                    ref = "delete-button",
                    text = "删除",
                    bounds = "[1,2][30,40]",
                    source = "a11y",
                ),
            ),
        )

        assertTrue(decision is SafetyDecision.ConfirmationRequired)
    }

    @Test
    fun `argument fingerprint is stable across JSON key order`() {
        val first = JSONObject().put("action", "click").put("ref", "r1")
        val reordered = JSONObject().put("ref", "r1").put("action", "click")

        assertEquals(SafetyPolicy.fingerprint(first), SafetyPolicy.fingerprint(reordered))
    }
}
