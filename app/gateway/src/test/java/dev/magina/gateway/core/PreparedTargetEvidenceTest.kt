package dev.magina.gateway.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.json.JSONObject
import org.junit.Test

class PreparedTargetEvidenceTest {
    private val nodeId = "7|com.tencent.mm:id/chat_input|android.widget.EditText|com.tencent.mm|10,20,100,80"
    private val imeSessionId = "ime|0123456789abcdef01234567"
    private var now = 1_000L
    private val store = PreparedTargetEvidenceStore(ttlMs = 500L, clock = { now })

    @Test
    fun `records only short lived target metadata and replaces previous target`() {
        val first = store.record(
            label = "文件传输助手",
            packageName = "com.tencent.mm",
            focusedInputId = nodeId,
            bounds = "[10,20][100,80]",
            imeSessionId = imeSessionId,
        )
        val second = store.record(
            label = "文件传输助手",
            packageName = "com.tencent.mm",
            focusedInputId = nodeId.replace("|10,", "|11,"),
            bounds = "[10,20][100,80]",
            imeSessionId = imeSessionId,
        )

        assertTrue(second.preparedId > first.preparedId)
        assertEquals(
            second,
            store.current(
                "com.tencent.mm",
                nodeId.replace("|10,", "|11,"),
                "[10,20][100,80]",
                imeSessionId,
            ),
        )
        store.record(
            label = "文件传输助手",
            packageName = "com.tencent.mm",
            focusedInputId = nodeId.replace("|10,", "|11,"),
            bounds = "[10,20][100,80]",
            imeSessionId = imeSessionId,
        )
        assertNull(store.current("com.tencent.mm", nodeId, "[10,20][100,80]", imeSessionId))
        assertEquals(
            setOf(
                "preparedId", "label", "packageName", "focusedInputId", "bounds", "imeSessionId",
                "preparedAtMs", "expiresAtMs",
            ),
            PreparedTargetEvidence::class.java.declaredFields
                .map { it.name }
                .filterNot { it.startsWith("$") }
                .toSet(),
        )
    }

    @Test
    fun `expiry package focus or bounds mismatch fail closed and clear target`() {
        fun seed() = store.record(
            label = "文件传输助手",
            packageName = "com.tencent.mm",
            focusedInputId = nodeId,
            bounds = "[10,20][100,80]",
            imeSessionId = imeSessionId,
        )

        seed()
        assertNull(store.current("other.package", nodeId, "[10,20][100,80]", imeSessionId))
        assertNull(store.current("com.tencent.mm", nodeId, "[10,20][100,80]", imeSessionId))

        seed()
        assertNull(store.current("com.tencent.mm", "other-node", "[10,20][100,80]", imeSessionId))
        assertNull(store.current("com.tencent.mm", nodeId, "[10,20][100,80]", imeSessionId))

        seed()
        assertNull(store.current("com.tencent.mm", nodeId, "[0,0][1,1]", imeSessionId))
        assertNull(store.current("com.tencent.mm", nodeId, "[10,20][100,80]", imeSessionId))

        seed()
        assertNull(
            store.current(
                "com.tencent.mm",
                nodeId,
                "[10,20][100,80]",
                "ime|fedcba9876543210fedcba98",
            ),
        )

        seed()
        now += 500
        assertNull(store.current("com.tencent.mm", nodeId, "[10,20][100,80]", imeSessionId))
    }

    @Test
    fun `prepared target blocks every explicit ref before type handler and clears both stores`() {
        listOf("other-ref", "same-ref").forEach { ref ->
            val prepared = seedPrepared()
            val input = InputCommitEvidenceStore().also {
                it.record("待发送", "input-1")
            }
            var handlerCalls = 0

            try {
                guardPreparedTargetTypeTextArgs(
                    args = JSONObject().put("text", "x").put("ref", ref),
                    preparedStore = prepared,
                    inputStore = input,
                )
                handlerCalls++
                fail("prepared target + ref must fail closed")
            } catch (error: GatewayError) {
                assertEquals(ErrorCode.E_BLOCKED, error.code)
            }

            assertEquals(0, handlerCalls)
            assertNull(prepared.peekActive())
            assertNull(input.current("input-1"))
        }
    }

    @Test
    fun `type text without prepared target keeps existing ref behavior`() {
        val prepared = PreparedTargetEvidenceStore(ttlMs = 500L, clock = { now })
        val input = InputCommitEvidenceStore()

        guardPreparedTargetTypeTextArgs(
            args = JSONObject().put("text", "x").put("ref", "legacy-ref"),
            preparedStore = prepared,
            inputStore = input,
        )
    }

    private fun seedPrepared(): PreparedTargetEvidenceStore =
        PreparedTargetEvidenceStore(ttlMs = 500L, clock = { now }).also {
            it.record(
                label = "文件传输助手",
                packageName = "com.tencent.mm",
                focusedInputId = nodeId,
                bounds = "[10,20][100,80]",
                imeSessionId = imeSessionId,
            )
        }
}
