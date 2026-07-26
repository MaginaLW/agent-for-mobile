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
    private val strict = FocusIdentity(IdentitySource.A11Y, nodeId, imeSessionId)
    private val degraded = FocusIdentity(IdentitySource.IME_ONLY, null, imeSessionId)
    private val bounds = "[10,20][100,80]"
    private var now = 1_000L
    private val store = PreparedTargetEvidenceStore(ttlMs = 500L, clock = { now })

    @Test
    fun `records only short lived target metadata and replaces previous target`() {
        val moved = FocusIdentity(IdentitySource.A11Y, nodeId.replace("|10,", "|11,"), imeSessionId)
        val first = store.record("文件传输助手", "com.tencent.mm", strict, bounds)
        val second = store.record("文件传输助手", "com.tencent.mm", moved, bounds)

        assertTrue(second.preparedId > first.preparedId)
        assertEquals(second, store.current("com.tencent.mm", moved, bounds))
        store.record("文件传输助手", "com.tencent.mm", moved, bounds)
        assertNull(store.current("com.tencent.mm", strict, bounds))
        assertEquals(
            setOf(
                "preparedId", "label", "packageName", "identity", "bounds",
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
        fun seed() = store.record("文件传输助手", "com.tencent.mm", strict, bounds)

        seed()
        assertNull(store.current("other.package", strict, bounds))
        assertNull(store.current("com.tencent.mm", strict, bounds))

        seed()
        assertNull(
            store.current(
                "com.tencent.mm",
                FocusIdentity(IdentitySource.A11Y, nodeId.replace("chat_input", "search"), imeSessionId),
                bounds,
            ),
        )
        assertNull(store.current("com.tencent.mm", strict, bounds))

        seed()
        assertNull(store.current("com.tencent.mm", strict, "[0,0][1,1]"))
        assertNull(store.current("com.tencent.mm", strict, bounds))

        seed()
        assertNull(
            store.current(
                "com.tencent.mm",
                FocusIdentity(IdentitySource.A11Y, nodeId, "ime|fedcba9876543210fedcba98"),
                bounds,
            ),
        )

        seed()
        now += 500
        assertNull(store.current("com.tencent.mm", strict, bounds))
    }

    /** design §3.1：a11y 与几何"都为空"绝不能因为 blank == blank 而平凡通过。 */
    @Test
    fun `strict target is never readable through a degraded identity`() {
        store.record("文件传输助手", "com.tencent.mm", strict, bounds)

        assertNull(store.current("com.tencent.mm", degraded, null))
        assertNull(store.current("com.tencent.mm", null, null))
    }

    /** design §3.3：IME-only 目标必须一致地缺失几何，带上 bounds 反而判错配。 */
    @Test
    fun `degraded target requires consistently absent bounds`() {
        val recorded = store.record("文件传输助手", "com.tencent.mm", degraded, null)

        assertEquals(recorded, store.current("com.tencent.mm", degraded, null))
        assertNull(store.current("com.tencent.mm", degraded, bounds))
        assertNull(store.current("com.tencent.mm", strict, null))
    }

    @Test
    fun `record rejects bounds inconsistent with identity source`() {
        listOf(
            { store.record("文件传输助手", "com.tencent.mm", strict, null) },
            { store.record("文件传输助手", "com.tencent.mm", strict, "") },
            { store.record("文件传输助手", "com.tencent.mm", degraded, bounds) },
        ).forEach { build ->
            try {
                build()
                fail("bounds 与身份来源错配必须记录失败")
            } catch (expected: IllegalArgumentException) {
                assertTrue(expected.message!!.isNotBlank())
            }
        }
    }

    @Test
    fun `prepared target blocks every explicit ref before type handler and clears both stores`() {
        listOf("other-ref", "same-ref").forEach { ref ->
            val prepared = seedPrepared()
            val input = InputCommitEvidenceStore().also {
                it.record("待发送", strict, readbackVerified = true)
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
            assertNull(input.current(strict))
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
            it.record("文件传输助手", "com.tencent.mm", strict, bounds)
        }
}
