package dev.magina.gateway.a11y

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 「标题读不回来」的**分因**（2026-08-08 批次 4 第三跑）。
 *
 * 那三跑的终态逐字相同，而手上只有「读不回来」五个字——四种完全不同的处境被折成了同一个
 * `null`。这个文件钉的就是"它们从此各有各的名字"，以及那条 note 字段的格式契约。
 */
class SurfaceTitleReadPolicyTest {

    private val screenWidth = 1260
    private val screenHeight = 2800
    private val titleCenterY = (screenHeight * 0.06).toInt()

    private fun snapshot(
        fusion: String,
        fgElements: Int = 0,
        note: String? = null,
        elements: List<JSONObject> = emptyList(),
        blockingOverlay: Boolean = false,
    ): JSONObject {
        val raw = JSONObject()
            .put("fusion", fusion)
            .put("fg_elements", fgElements)
            .put("revision", 41L)
            .put("capture_revision", 41L)
            .put("vision_generation", 7L)
            .put("foreground_window_id", 9)
            .put("foreground_known", true)
            .put("foreground_package", "com.tencent.mm")
            .put("blocking_overlay", blockingOverlay)
            .put("elements", JSONArray().also { array -> elements.forEach(array::put) })
        note?.let { raw.put("note", it) }
        return raw
    }

    private fun element(
        text: String = "文件传输助手",
        source: String = "ocr",
        confidence: Double? = 0.55,
        centerX: Int = screenWidth / 2,
        centerY: Int = titleCenterY,
        role: String = "text",
    ): JSONObject {
        val json = JSONObject()
            .put("ref", "o1")
            .put("role", role)
            .put("text", text)
            .put("desc", "")
            .put("source", source)
            .put(
                "bounds",
                JSONArray(listOf(centerX - 200, centerY - 30, centerX + 200, centerY + 30)),
            )
        confidence?.let { json.put("confidence", it) }
        return json
    }

    private fun classify(raw: JSONObject?, elapsedMs: Long = 0L) =
        SurfaceTitleReadPolicy.classify(raw, screenWidth, screenHeight, elapsedMs)

    // —— 四种处境各有各的名字 ——

    @Test
    fun `perception throwing is its own outcome`() {
        val attempt = classify(null)
        assertEquals(SurfaceTitleOutcome.NO_SNAPSHOT, attempt.outcome)
        assertNull(attempt.title)
    }

    @Test
    fun `no fusion on this frame is not the same as nothing in the title band`() {
        // 融合闸门没放行：前台 a11y 元素够稠密，这一帧压根没跑识别。
        val attempt = classify(snapshot(fusion = "none", fgElements = 12))
        assertEquals(SurfaceTitleOutcome.NO_OCR, attempt.outcome)
        // **闸门那个数要能被现场直接读出来**，否则"是不是闸门挡的"还得靠猜。
        assertEquals(12, attempt.fgElements)
        assertTrue(attempt.fgElements >= OCR_FUSION_FG_THRESHOLD)
    }

    @Test
    fun `fusion that blew up degrades silently in snapshot but not here`() {
        // `snapshot()` 把融合异常 catch 成一句 note 后照常返回——读取侧看到的仍是 fusion=none。
        // 这一条钉的是：那句 note 不会被丢掉。
        val attempt = classify(
            snapshot(fusion = "none", note = "OCR 融合失败，降级纯 a11y：截图与请求 revision 不一致"),
        )
        assertEquals(SurfaceTitleOutcome.NO_OCR, attempt.outcome)
        assertTrue(attempt.note.contains("revision"))
    }

    @Test
    fun `ocr ran but title band is empty`() {
        val attempt = classify(
            snapshot(fusion = "ocr", elements = listOf(element(centerY = (screenHeight * 0.5).toInt()))),
        )
        assertEquals(SurfaceTitleOutcome.NO_CANDIDATE, attempt.outcome)
        assertEquals(0, attempt.bandElements)
    }

    @Test
    fun `title band had a candidate but the confidence gate rejected it`() {
        val attempt = classify(
            snapshot(fusion = "ocr", elements = listOf(element(confidence = 0.30))),
        )
        assertEquals(SurfaceTitleOutcome.ALL_REJECTED, attempt.outcome)
        assertEquals(1, attempt.bandElements)
        // 差多少要能看见：0.30 对 0.45，现场一眼能判断"门槛问题"还是"根本没读到字"。
        assertEquals(0.30, attempt.bestRejectedConfidence!!, 1e-9)
        assertTrue(attempt.bestRejectedConfidence!! < MIN_RECOGNITION_OCR_CONFIDENCE)
    }

    @Test
    fun `resolved returns the very element toolbarTitle would have picked`() {
        val raw = snapshot(fusion = "ocr", elements = listOf(element()))
        val attempt = classify(raw)
        assertEquals(SurfaceTitleOutcome.RESOLVED, attempt.outcome)
        assertNotNull(attempt.title)
        // 读取侧不许另写一份选取规则：这里选出来的必须就是 toolbarTitle 选出来的那一个。
        val viaPolicy = ConversationSurfacePolicy.toolbarTitle(
            ConversationSurfacePolicy.decodeElements(raw, screenHeight),
            SurfaceFrame.of(raw, screenWidth, screenHeight),
        )
        assertEquals(viaPolicy, attempt.title)
    }

    @Test
    fun `blocking overlay makes an otherwise matching OCR title unresolved`() {
        val attempt = classify(
            snapshot(
                fusion = "ocr",
                elements = listOf(element(text = "张三")),
                blockingOverlay = true,
            ),
        )

        assertFalse("blocking overlays must be unresolved", attempt.outcome == SurfaceTitleOutcome.RESOLVED)
        assertNull("overlay text must never rebuild the underlying conversation", attempt.title)
        assertTrue("the blocking fact must survive classification", attempt.capture?.blockingOverlay == true)
        assertNull(SurfaceTitleRead(listOf(attempt), waitedMs = 0).bundle)
        assertFalse(
            "a later clear frame must not erase the fact that this rebuild observed an overlay",
            SurfaceTitleReadPolicy.shouldRetry(attempt, attemptsSoFar = 1, elapsedMs = 0),
        )
    }

    @Test
    fun `resolved title cannot form a rebuild bundle without same capture input proof`() {
        val attempt = classify(snapshot(fusion = "ocr", elements = listOf(element(text = "张三"))))
        assertNull(SurfaceTitleRead(listOf(attempt), waitedMs = 0).bundle)

        val capture = requireNotNull(attempt.capture)
        val inputProof = FreshPreparedInputProof(
            captureRevision = capture.captureRevision,
            foregroundWindowId = capture.foregroundWindowId,
            visionGeneration = capture.visionGeneration,
            nodePresent = false,
            nodeId = null,
            imeSessionId = "ime|0123456789abcdef01234567",
            focused = false,
            editable = false,
            left = 0,
            top = 0,
            right = 0,
            bottom = 0,
        )
        val bundle = SurfaceTitleRead(listOf(attempt.copy(inputProof = inputProof)), waitedMs = 0).bundle

        assertNotNull(bundle)
        assertEquals(capture.visionGeneration, bundle!!.input.visionGeneration)
        assertEquals("张三", bundle.surface.canonicalLabel)
    }

    // —— 重试：有界，且只重试"读" ——

    @Test
    fun `retry stops the moment the title resolves`() {
        val resolved = classify(snapshot(fusion = "ocr", elements = listOf(element())))
        assertFalse(SurfaceTitleReadPolicy.shouldRetry(resolved, attemptsSoFar = 1, elapsedMs = 0))
    }

    @Test
    fun `retry is bounded by both attempts and budget`() {
        val failed = classify(snapshot(fusion = "none"))
        assertTrue(SurfaceTitleReadPolicy.shouldRetry(failed, attemptsSoFar = 1, elapsedMs = 0))
        assertFalse(
            SurfaceTitleReadPolicy.shouldRetry(
                failed,
                attemptsSoFar = SurfaceTitleReadPolicy.MAX_ATTEMPTS,
                elapsedMs = 0,
            ),
        )
        // 预算这一道单独拦：一次读本身可能就很慢（强制新截图 + 全屏识别）。
        assertFalse(
            SurfaceTitleReadPolicy.shouldRetry(
                failed,
                attemptsSoFar = 1,
                elapsedMs = SurfaceTitleReadPolicy.BUDGET_MS,
            ),
        )
    }

    @Test
    fun `budget can actually hold the advertised number of attempts`() {
        // 这条与 SurfaceTitleReadPolicy 的构造断言是同一件事，写成用例是为了"改了数就有人红"：
        // 预算装不下 MAX_ATTEMPTS 时，现场看到 attempts=2 会以为"只读了两次就放弃"。
        assertTrue(
            (SurfaceTitleReadPolicy.MAX_ATTEMPTS - 1) * SurfaceTitleReadPolicy.RETRY_INTERVAL_MS <
                SurfaceTitleReadPolicy.BUDGET_MS,
        )
    }

    // —— 落进审计 note 的那一段：格式契约 ——

    @Test
    fun `describe pins the exact wire format`() {
        // **这份 fixture 刻意不带 note**：note 那条泄漏由下一个用例单独看着。
        // 两条断言挤进同一个用例的话，格式一改就得改期望串，而"值里混进分号"会跟着被顺手改掉
        // ——那正是「断言个数>0 会替坏掉的注入打掩护」的形状。
        val read = SurfaceTitleRead(
            attempts = listOf(
                classify(snapshot(fusion = "none")),
                classify(snapshot(fusion = "ocr", elements = listOf(element()))),
            ),
            waitedMs = 1420,
        )
        assertEquals(
            "attempts=2,waited_ms=1420,result=resolved,resolved_at=2," +
                "trail=no_ocr+resolved,fg=0+0,band=0+1,sysrej=0+0,topcut=0+0,picked=ocr",
            read.describe(),
        )
    }

    @Test
    fun `describe never emits the field separator that just bit us`() {
        // 2026-08-08：`foreground_wait` 的 last= 用 \S* 贪吃，把后面两段整个吞掉。
        // 新字段从第一天就钉住"值里不出现分隔符"，而不是等 runner 那边再被吞一次。
        // 唯一可能带进分隔符的是快照自报的那句 note（异常原文，什么字符都可能有）。
        val read = SurfaceTitleRead(
            attempts = listOf(classify(snapshot(fusion = "none", note = "OCR 融合失败：a;b,c=d"))),
            waitedMs = 30,
        )
        assertFalse(read.describe().contains(';'))
    }

    @Test
    fun `unresolved read says so and points at the last attempt`() {
        val read = SurfaceTitleRead(
            attempts = List(3) { classify(snapshot(fusion = "none", fgElements = 9)) },
            waitedMs = 2100,
        )
        assertNull(read.title)
        assertEquals(0, read.resolvedAt)
        assertTrue(read.describe().contains("result=unresolved"))
        // **这一句才是三跑之后我们真正想要的那句话**：三次结论相同 → 不是时机问题。
        assertTrue(read.detail().contains("不是时机问题"))
        assertTrue(read.detail().contains("9"))
    }

    @Test
    fun `a read that only succeeded after retrying reads as a timing problem`() {
        val read = SurfaceTitleRead(
            attempts = listOf(
                classify(snapshot(fusion = "none")),
                classify(snapshot(fusion = "ocr", elements = listOf(element()))),
            ),
            waitedMs = 900,
        )
        assertEquals(2, read.resolvedAt)
        assertNotNull(read.title)
        // 判据在 EvidenceRebuildPolicy，那边只关心"有没有标题"；这里只保证痕迹分得开。
        assertTrue(read.describe().contains("trail=no_ocr+resolved"))
    }

    @Test
    fun `detail carries the snapshot note but describe does not`() {
        val read = SurfaceTitleRead(
            attempts = listOf(classify(snapshot(fusion = "none", note = "OCR 融合失败，降级纯 a11y：boom"))),
            waitedMs = 40,
        )
        assertTrue(read.detail().contains("boom"))
        assertFalse(read.describe().contains("boom"))
    }
}
