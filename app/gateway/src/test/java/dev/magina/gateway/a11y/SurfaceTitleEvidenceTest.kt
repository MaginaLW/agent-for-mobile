package dev.magina.gateway.a11y

import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.Envelope
import dev.magina.gateway.core.GatewayError
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SurfaceTitleEvidenceTest {

    private val selectedText = "|8月5日2050"
    private val targetText = "文件传输助手"
    private val secretNoise = "secret-token-that-must-never-enter-persistent-evidence"

    @Test
    fun `fresh title evidence persists geometry and reason without OCR text`() {
        val evidence = SurfaceTitleEvidence.from(readWithCandidates())
        val json = evidence.toJson()
        val serialized = json.toString()

        assertEquals(1, json.getInt("schema_version"))
        assertEquals("conversation_surface_policy", json.getString("selection_reason"))
        assertEquals(3, json.getInt("candidate_count"))
        assertFalse(json.getBoolean("candidates_truncated"))

        val selected = json.getJSONObject("selected")
        assertEquals(0, selected.getInt("ordinal"))
        assertEquals("ocr", selected.getString("source"))
        assertEquals(9, selected.getInt("normalized_length"))
        assertEquals("selected", selected.getString("decision"))
        assertEquals("430:130:830:190", selected.getString("bounds"))
        assertTrue(selected.getString("text_sha256").matches(Regex("[0-9a-f]{64}")))

        val candidates = json.getJSONArray("candidates")
        assertEquals("selected", candidates.getJSONObject(0).getString("decision"))
        assertEquals("eligible_not_selected", candidates.getJSONObject(1).getString("decision"))
        assertEquals("rejected_confidence", candidates.getJSONObject(2).getString("decision"))
        assertNotEquals(
            candidates.getJSONObject(0).getString("text_sha256"),
            candidates.getJSONObject(1).getString("text_sha256"),
        )

        listOf(selectedText, targetText, secretNoise).forEach { raw ->
            assertFalse("候选原文泄漏到 JSON：$raw", serialized.contains(raw))
            assertFalse("候选原文泄漏到 audit token：$raw", evidence.auditToken.contains(raw))
        }
        assertTrue(evidence.auditToken.matches(Regex("[A-Za-z0-9_-]+")))
    }

    @Test
    fun `attaching title evidence sanitizes the complete error envelope`() {
        val rawFailure =
            "最终 fresh 标题或内容判不了：标题读回「$selectedText」，与已批准会话「$targetText」不一致"
        val original = GatewayError(
            ErrorCode.E_VERIFY_FAIL,
            rawFailure,
            channel = "vision",
            retryable = false,
            fallback = "不得重试",
            extra = JSONObject().put("existing", "kept"),
        )

        val enriched = SurfaceTitleEvidence.attach(original, readWithCandidates())

        assertEquals(original.code, enriched.code)
        assertEquals("最终 fresh 标题或内容无法机械验证；见 error.extra.title_read 脱敏证据", enriched.message)
        assertEquals(original.channel, enriched.channel)
        assertEquals(original.retryable, enriched.retryable)
        assertEquals(original.fallback, enriched.fallback)
        assertEquals("kept", enriched.extra!!.getString("existing"))
        assertTrue(enriched.extra!!.has("title_read"))
        val failure = enriched.extra!!.getJSONObject("title_read_failure")
        assertEquals(rawFailure.length, failure.getInt("message_length"))
        assertTrue(failure.getString("message_sha256").matches(Regex("[0-9a-f]{64}")))
        assertFalse(enriched.extra!!.has("enter_diagnostics"))

        val envelope = Envelope.err(enriched, JSONObject(), "a-test").toString()
        assertFalse(envelope.contains(selectedText))
        assertFalse(envelope.contains(targetText))
        assertFalse(envelope.contains(rawFailure))

        val fields = SurfaceTitleEvidence.auditFields(enriched)
        assertEquals(2, fields.size)
        assertTrue(fields[0].startsWith("final_title_read=attempts=1,"))
        assertTrue(fields[1].matches(Regex("title_evidence=[A-Za-z0-9_-]+")))
        val persistent = fields.joinToString(";") + enriched.extra.toString()
        listOf(selectedText, targetText, secretNoise).forEach { raw ->
            assertFalse("候选原文泄漏到持久摘要：$raw", persistent.contains(raw))
        }
    }

    @Test
    fun `selected candidate beyond persistence cap is still retained`() {
        val candidates = (0..13).map { ordinal ->
            val element = element(
                text = "candidate-$ordinal",
                bounds = SurfaceRect(400, 120 + ordinal, 840, 180 + ordinal),
                source = "ocr",
            )
            candidate(element)
        }
        val selectedCandidate = candidates.last()
        val selectedElement = element(
            text = selectedCandidate.text,
            bounds = selectedCandidate.bounds,
            source = selectedCandidate.source,
        )
        val read = SurfaceTitleRead(
            attempts = listOf(
                SurfaceTitleAttempt(
                    outcome = SurfaceTitleOutcome.RESOLVED,
                    elapsedMs = 700,
                    fusion = "ocr",
                    fgElements = 0,
                    bandElements = candidates.size,
                    bestRejectedConfidence = null,
                    note = "",
                    capture = capture(),
                    title = selectedElement,
                    candidates = candidates,
                ),
            ),
            waitedMs = 700,
        )

        val json = SurfaceTitleEvidence.from(read).toJson()
        assertTrue(json.getBoolean("candidates_truncated"))
        assertEquals(14, json.getInt("candidate_count"))
        assertEquals(12, json.getJSONArray("candidates").length())
        assertEquals(13, json.getJSONObject("selected").getInt("ordinal"))
        assertTrue(
            (0 until json.getJSONArray("candidates").length())
                .map { json.getJSONArray("candidates").getJSONObject(it).getInt("ordinal") }
                .contains(13),
        )
    }

    @Test
    fun `safe downstream failure keeps its diagnostic while title evidence is attached`() {
        val message = "最终 fresh 输入身份或几何与已复核证据不一致"
        val original = GatewayError(
            ErrorCode.E_STALE_REF,
            message,
            channel = "safety",
            retryable = false,
        )

        val enriched = SurfaceTitleEvidence.attach(original, readWithCandidates())

        assertEquals(message, enriched.message)
        assertTrue(enriched.extra!!.has("title_read"))
        assertFalse(enriched.extra!!.has("title_read_failure"))
    }

    private fun readWithCandidates(): SurfaceTitleRead {
        val selected = element(selectedText, SurfaceRect(430, 130, 830, 190), source = "ocr")
        val target = element(targetText, SurfaceRect(420, 150, 840, 215), source = "ocr")
        val rejected = SurfaceCandidate(
            text = secretNoise,
            bounds = SurfaceRect(450, 180, 810, 230),
            source = "ocr",
            windowId = null,
            foregroundWindow = false,
            rejectedBy = SurfaceCandidate.REJECT_CONFIDENCE,
        )
        return SurfaceTitleRead(
            attempts = listOf(
                SurfaceTitleAttempt(
                    outcome = SurfaceTitleOutcome.RESOLVED,
                    elapsedMs = 510,
                    fusion = "ocr",
                    fgElements = 0,
                    bandElements = 3,
                    bestRejectedConfidence = 0.42,
                    note = "",
                    capture = capture(),
                    title = selected,
                    candidates = listOf(
                        candidate(selected),
                        candidate(target),
                        rejected,
                    ),
                ),
            ),
            waitedMs = 510,
        )
    }

    private fun candidate(element: SurfaceElement) = SurfaceCandidate(
        text = element.text,
        bounds = element.bounds,
        source = element.source,
        windowId = element.windowId,
        foregroundWindow = element.foregroundWindow,
        rejectedBy = null,
    )

    private fun element(text: String, bounds: SurfaceRect, source: String) = SurfaceElement(
        ref = "ocr-${text.length}",
        role = "text",
        text = text,
        description = "",
        bounds = bounds,
        source = source,
        confidence = 0.88,
        stage = SurfaceStage.TOOLBAR,
        windowId = null,
        foregroundWindow = false,
    )

    private fun capture() = FreshEvidenceCapture(
        revision = 27,
        captureRevision = 27,
        visionGeneration = 4,
        foregroundWindowId = 9,
        foregroundKnown = true,
        foregroundPackage = "com.tencent.mm",
        blockingOverlay = false,
    )
}
