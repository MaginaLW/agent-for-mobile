package dev.magina.gateway.a11y

import dev.magina.gateway.core.IntentReadbackChannel
import dev.magina.gateway.mcp.parseConversationTitleElements
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ConversationTitlePolicyTest {

    private fun element(
        text: String,
        desc: String = "",
        source: String = "a11y",
        conf: Double? = null,
        left: Int = 450,
        top: Int = 60,
        right: Int = 650,
        bottom: Int = 110,
    ) = ConversationTitleElement(text, desc, source, conf, left, top, right, bottom)

    @Test
    fun `extracts unique trusted title in toolbar band and prefers a11y over ocr`() {
        val observed = ConversationTitlePolicy.readTitle(
            elements = listOf(
                element(text = "文件传输助手", source = "a11y"),
                element(text = "文件传输助手8", source = "ocr", conf = 0.88),
            ),
            regionLeft = 0,
            regionTop = 0,
            regionWidth = 1080,
            regionHeight = 2400,
            blockingOverlay = false,
        )
        assertEquals("文件传输助手", observed?.label)
        assertEquals(IntentReadbackChannel.A11Y, observed?.channel)
    }

    @Test
    fun `supports right pane region in same_app_multi landscape layout`() {
        // 右半屏区域 x=[1000..2800], width=1800, height=1800 -> centerX 需落入 [1540..2260]
        val observed = ConversationTitlePolicy.readTitle(
            elements = listOf(
                element(text = "微信", source = "ocr", conf = 0.90, left = 400, top = 50, right = 520, bottom = 100),
                element(text = "文件传输助手", source = "ocr", conf = 0.56, left = 1780, top = 60, right = 2020, bottom = 120),
            ),
            regionLeft = 1000,
            regionTop = 0,
            regionWidth = 1800,
            regionHeight = 1800,
            blockingOverlay = false,
        )
        assertEquals("文件传输助手", observed?.label)
        assertEquals(IntentReadbackChannel.OCR, observed?.channel)
    }

    @Test
    fun `filters status bar noise and rejects low confidence or ambiguous candidates`() {
        // 状态栏时间与网速被过滤，不污染唯一标题
        val clean = ConversationTitlePolicy.readTitle(
            elements = listOf(
                element(text = "22:45", source = "ocr", conf = 0.95),
                element(text = "1.2MB/s", source = "ocr", conf = 0.95),
                element(text = "95%", source = "ocr", conf = 0.95),
                element(text = "产品讨论群", source = "ocr", conf = 0.50),
            ),
            regionLeft = 0,
            regionTop = 0,
            regionWidth = 1080,
            regionHeight = 2400,
            blockingOverlay = false,
        )
        assertEquals("产品讨论群", clean?.label)

        // 低置信度 (< 0.45) 拒绝
        assertNull(
            ConversationTitlePolicy.readTitle(
                elements = listOf(element(text = "产品讨论群", source = "ocr", conf = 0.44)),
                regionLeft = 0,
                regionTop = 0,
                regionWidth = 1080,
                regionHeight = 2400,
                blockingOverlay = false,
            ),
        )

        // 两个不同标题候选 fail-closed
        assertNull(
            ConversationTitlePolicy.readTitle(
                elements = listOf(
                    element(text = "张三", source = "a11y", left = 420, right = 500),
                    element(text = "李四", source = "a11y", left = 560, right = 660),
                ),
                regionLeft = 0,
                regionTop = 0,
                regionWidth = 1080,
                regionHeight = 2400,
                blockingOverlay = false,
            ),
        )

        // 遮挡浮层直接返回 null
        assertNull(
            ConversationTitlePolicy.readTitle(
                elements = listOf(element(text = "文件传输助手", source = "a11y")),
                regionLeft = 0,
                regionTop = 0,
                regionWidth = 1080,
                regionHeight = 2400,
                blockingOverlay = true,
            ),
        )
    }

    @Test
    fun `parseConversationTitleElements filters by pane cleanly`() {
        val snap = JSONObject().put(
            "elements",
            JSONArray()
                .put(
                    JSONObject().put("text", "左标题").put("desc", "").put("source", "ocr")
                        .put("confidence", 0.8).put("pane", "left")
                        .put("bounds", JSONArray(listOf(100, 50, 200, 90))),
                )
                .put(
                    JSONObject().put("text", "右标题").put("desc", "").put("source", "ocr")
                        .put("confidence", 0.8).put("pane", "right")
                        .put("bounds", JSONArray(listOf(1500, 50, 1700, 90))),
                ),
        )
        val rightOnly = parseConversationTitleElements(snap, paneFilter = "right")
        assertEquals(listOf("右标题"), rightOnly.map { it.text })
    }
}
