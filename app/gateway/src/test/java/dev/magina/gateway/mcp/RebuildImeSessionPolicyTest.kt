package dev.magina.gateway.mcp

import android.view.inputmethod.InputConnection
import dev.magina.gateway.core.ApprovalIntent
import dev.magina.gateway.core.EvidenceRebuild
import dev.magina.gateway.core.FocusIdentity
import dev.magina.gateway.core.InputCommitEvidenceStore
import dev.magina.gateway.core.PreparedTargetEvidenceStore
import dev.magina.gateway.core.RiskTier
import dev.magina.gateway.ime.ImeBridge
import dev.magina.gateway.ime.ImeSessionIdentity
import org.junit.After
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.lang.reflect.Proxy

class RebuildImeSessionPolicyTest {

    @After
    fun cleanup() = ImeBridge.finishSession()

    private val intent = ApprovalIntent(
        intentId = "intent-1",
        riskTier = RiskTier.RETRACTABLE,
        actionKind = "发送消息",
        targetPackage = "com.tencent.mm",
        targetLabel = "张三",
        createdAtMs = 1_000,
    )

    @Test
    fun `rebuild rejects a connected IME session owned by another package`() {
        ImeBridge.startSession(
            "ime|1234567890abcdef12345678",
            "com.example.other",
            null,
        ) { fakeConnection() }

        val failure = rebuildImeSessionFailure(intent, ImeBridge.session())

        assertTrue(failure is EvidenceRebuild.Unverified)
        assertTrue(failure!!.reason.contains("com.tencent.mm"))
        assertTrue(failure.reason.contains("com.example.other"))
    }

    @Test
    fun `rebuild accepts only a connected session owned by the intent package`() {
        assertNull(
            rebuildImeSessionFailure(
                intent,
                ImeSessionIdentity("ime|1234567890abcdef12345678", "com.tencent.mm", connected = true),
            ),
        )
        assertTrue(
            rebuildImeSessionFailure(
                intent,
                ImeSessionIdentity("ime|1234567890abcdef12345678", "com.tencent.mm", connected = false),
            ) is EvidenceRebuild.Unverified,
        )
    }

    @Test
    fun `rebuild keeps the same session id across the slow read`() {
        val failure = rebuildImeSessionFailure(
            intent = intent,
            session = ImeSessionIdentity(
                "ime|abcdef1234567890abcdef12",
                "com.tencent.mm",
                connected = true,
            ),
            expectedSessionId = "ime|1234567890abcdef12345678",
        )

        assertTrue(failure is EvidenceRebuild.Unverified)
        assertTrue(failure!!.reason.contains("会话已切换"))
    }

    @Test
    fun `rebuild entry clears both old stores before any channel early return`() {
        val prepared = PreparedTargetEvidenceStore()
        val input = InputCommitEvidenceStore()
        val identity = requireNotNull(
            FocusIdentity.of(
                "9|chat_input|EditText|com.tencent.mm|100,1600,980,1760",
                "ime|1234567890abcdef12345678",
            ),
        )
        prepared.record("旧会话", "com.tencent.mm", identity, "[100,1600][980,1760]")
        input.record("old content", identity, readbackVerified = true)

        clearEvidenceAtRebuildEntry(prepared, input)

        assertNull(prepared.peekActive())
        assertNull(input.current(identity))
    }

    private fun fakeConnection(): InputConnection = Proxy.newProxyInstance(
        InputConnection::class.java.classLoader,
        arrayOf(InputConnection::class.java),
    ) { _, method, _ ->
        when (method.returnType) {
            java.lang.Boolean.TYPE -> false
            java.lang.Integer.TYPE -> 0
            else -> null
        }
    } as InputConnection
}
