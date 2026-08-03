package dev.magina.gateway.a11y

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 会话页识别下沉到 `src/main` 之后的离线用例（spec §9.6 / backlog §8）。
 *
 * 下沉的全部意义是**只有一份判据**：宏（大脑侧）与执行前重建（网关内部）调的是同一个对象。
 * 所以这里既钉几何/门槛/宽松匹配这些规则本身，也钉"两个入口给出的是同一个结论"。
 *
 * **这个文件在 `src/test`，两个变体都会跑**——`testReleaseUnitTest` 能跑通它，就是
 * "标题识别在 release 构建里也在"的机械证据。backlog §8 那条退路（debug-only + 显式断言 +
 * 一条钉住 release 恒为 Unverified 的用例）因此不需要了：下沉真的做成了。
 */
class ConversationSurfacePolicyTest {

    private val screenWidth = 1260
    private val screenHeight = 2800

    private fun element(
        text: String = "文件传输助手",
        source: String = "ocr",
        confidence: Double? = 0.55,
        centerX: Int = screenWidth / 2,
        centerY: Int = (screenHeight * 0.06).toInt(),
        role: String = "text",
    ): SurfaceElement {
        val bounds = SurfaceRect(centerX - 200, centerY - 30, centerX + 200, centerY + 30)
        return SurfaceElement(
            ref = "e1",
            role = role,
            text = text,
            description = "",
            bounds = bounds,
            source = source,
            confidence = confidence,
            stage = ConversationSurfacePolicy.stageOf(role, text, centerY, screenHeight),
        )
    }

    // —— stage 划分（判据挂在它上面，所以它先得对） ——

    @Test
    fun `stage classification follows the bands the macro has always used`() {
        assertEquals(
            SurfaceStage.TOOLBAR,
            ConversationSurfacePolicy.stageOf("text", "文件传输助手", (screenHeight * 0.06).toInt(), screenHeight),
        )
        assertEquals(
            SurfaceStage.BOTTOM_INPUT,
            ConversationSurfacePolicy.stageOf("input", "", (screenHeight * 0.9).toInt(), screenHeight),
        )
        assertEquals(
            SurfaceStage.CONTENT,
            ConversationSurfacePolicy.stageOf("text", "随便", (screenHeight * 0.5).toInt(), screenHeight),
        )
        // 顶部的输入框与「搜索」「取消」优先归 SEARCH，压过标题带
        assertEquals(
            SurfaceStage.SEARCH,
            ConversationSurfacePolicy.stageOf("input", "", (screenHeight * 0.06).toInt(), screenHeight),
        )
        assertEquals(
            SurfaceStage.SEARCH,
            ConversationSurfacePolicy.stageOf("text", "搜 索", (screenHeight * 0.06).toInt(), screenHeight),
        )
    }

    // —— 识别门槛与几何 ——

    @Test
    fun `recognition accepts ocr confidence below the action threshold`() {
        // 2026-07-23 真机实锤：页面级标题置信度落在 0.5~0.65，过不了点击级门槛。
        // 识别级门槛存在的全部理由就是这个，别把它调回去。
        assertTrue(MIN_RECOGNITION_OCR_CONFIDENCE < MIN_ACTION_OCR_CONFIDENCE)
        assertNotNull(
            ConversationSurfacePolicy.conversationTitle(
                listOf(element(confidence = 0.55)), screenWidth, screenHeight, "文件传输助手",
            ),
        )
    }

    @Test
    fun `recognition rejects ocr below the recognition threshold`() {
        assertNull(
            ConversationSurfacePolicy.conversationTitle(
                listOf(element(confidence = 0.30)), screenWidth, screenHeight, "文件传输助手",
            ),
        )
    }

    @Test
    fun `recognition rejects text outside the title band`() {
        val tooLow = element(centerY = (screenHeight * 0.5).toInt())
        val offCenter = element(centerX = (screenWidth * 0.1).toInt())
        assertNull(
            ConversationSurfacePolicy.conversationTitle(listOf(tooLow), screenWidth, screenHeight, "文件传输助手"),
        )
        assertNull(
            ConversationSurfacePolicy.conversationTitle(listOf(offCenter), screenWidth, screenHeight, "文件传输助手"),
        )
    }

    @Test
    fun `recognition rejects bounds that fall outside the screen`() {
        val broken = element().let {
            it.copy(bounds = SurfaceRect(-1, it.bounds.top, it.bounds.right, it.bounds.bottom))
        }
        assertNull(
            ConversationSurfacePolicy.conversationTitle(listOf(broken), screenWidth, screenHeight, "文件传输助手"),
        )
    }

    @Test
    fun `zero sized screen recognizes nothing instead of dividing by it`() {
        assertNull(ConversationSurfacePolicy.conversationTitle(listOf(element()), 0, 0, "文件传输助手"))
        assertNull(ConversationSurfacePolicy.toolbarTitle(listOf(element()), 0, 0))
    }

    // —— 宽松匹配：这是宏那条真机实锤的规则，下沉之后一字未改 ——

    @Test
    fun `ocr noise on the tail still recognizes the conversation`() {
        assertNotNull(
            ConversationSurfacePolicy.conversationTitle(
                listOf(element(text = "文件传输助手8")), screenWidth, screenHeight, "文件传输助手",
            ),
        )
    }

    @Test
    fun `another conversation is not recognized as the expected one`() {
        assertNull(
            ConversationSurfacePolicy.conversationTitle(
                listOf(element(text = "微信")), screenWidth, screenHeight, "文件传输助手",
            ),
        )
    }

    // —— 两个入口一份判据 ——

    @Test
    fun `toolbarTitle reads whatever is on the band without judging it`() {
        // 生产侧要的正是这个：先拿到"标题带上到底写着什么"，再由 EvidenceRebuildPolicy 去比。
        // 把比对塞进读取器，判据就变成"读回来的和读回来的一样"（发送后验踩过这个坑）。
        val other = element(text = "微信")
        val read = ConversationSurfacePolicy.toolbarTitle(listOf(other), screenWidth, screenHeight)
        assertEquals("微信", read?.text)
    }

    @Test
    fun `both entries agree because they share one implementation`() {
        val elements = listOf(element(text = "文件传输助手8"))
        val recognized =
            ConversationSurfacePolicy.conversationTitle(elements, screenWidth, screenHeight, "文件传输助手")
        val read = ConversationSurfacePolicy.toolbarTitle(elements, screenWidth, screenHeight)
        assertEquals(read, recognized)
        assertTrue(
            ConversationSurfacePolicy.isConversationSurface(
                elements, screenWidth, screenHeight, "文件传输助手",
            ),
        )
    }

    @Test
    fun `an untrusted element is invisible to both entries alike`() {
        val elements = listOf(element(confidence = 0.10))
        assertNull(ConversationSurfacePolicy.toolbarTitle(elements, screenWidth, screenHeight))
        assertNull(
            ConversationSurfacePolicy.conversationTitle(elements, screenWidth, screenHeight, "文件传输助手"),
        )
    }

    // —— JSON 解码：宏与生产解的是同一个 snapshot ——

    @Test
    fun `decode maps snapshot json into elements with stages`() {
        val raw = JSONObject().put(
            "elements",
            JSONArray()
                .put(
                    JSONObject()
                        .put("ref", "r1").put("role", "text").put("text", "文件传输助手")
                        .put("source", "ocr").put("confidence", 0.55)
                        .put("bounds", JSONArray(listOf(430, 138, 830, 198))),
                )
                // bounds 少一个数：跳过，不是造一个退化矩形
                .put(JSONObject().put("ref", "r2").put("bounds", JSONArray(listOf(1, 2, 3))))
                // 没有 bounds：跳过
                .put(JSONObject().put("ref", "r3").put("text", "无几何")),
        )
        val elements = ConversationSurfacePolicy.decodeElements(raw, screenHeight)
        assertEquals(1, elements.size)
        assertEquals(SurfaceStage.TOOLBAR, elements[0].stage)
        assertEquals(0.55, elements[0].confidence!!, 1e-9)
        assertNotNull(
            ConversationSurfacePolicy.conversationTitle(elements, screenWidth, screenHeight, "文件传输助手"),
        )
    }

    @Test
    fun `decode of a snapshot without elements is empty rather than throwing`() {
        assertEquals(0, ConversationSurfacePolicy.decodeElements(JSONObject(), screenHeight).size)
    }
}
