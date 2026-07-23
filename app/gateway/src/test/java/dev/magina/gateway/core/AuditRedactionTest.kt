package dev.magina.gateway.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AuditRedactionTest {
    @Test
    fun `type text audit line contains only length and hash never plaintext`() {
        val secret = "仅用于审计脱敏回归的秘密文本-7f83"
        val original = JSONObject()
            .put("text", secret)
            .put("mode", "replace")
            .put("ref", "e7")

        val sanitized = sanitizeAuditArgs("type_text", original)
        val line = buildAuditLine(
            timestamp = "2026-07-22T10:00:00.000",
            auditId = "a-000001",
            tool = "type_text",
            args = sanitized,
            okCode = "OK",
            channel = "a11y",
            elapsedMs = 12,
            note = "",
        ).toString()

        assertFalse(line.contains(secret))
        assertFalse(sanitized.has("text"))
        assertEquals(secret.length, sanitized.getInt("text_length"))
        assertEquals(InputCommitEvidence.sha256(secret), sanitized.getString("text_sha256"))
        assertEquals("replace", sanitized.getString("mode"))
        assertEquals(secret, original.getString("text"))
    }

    @Test
    fun `other tool audit args are copied without mutation`() {
        val original = JSONObject().put("key", "home")
        val sanitized = sanitizeAuditArgs("press_key", original)

        original.put("key", "enter")
        assertTrue(sanitized.getString("key") == "home")
    }
}
