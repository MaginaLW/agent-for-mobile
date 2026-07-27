package dev.magina.gateway.a11y

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 融合判定的离线回归。这段逻辑此前埋在 `snapshot()` 的 55 行循环里，改一处要烧一轮真机才知道对不对。
 *
 * 归一化在真机上是 `OcrEngine.norm`（全角/大小写/o→0 等）；这里注入一个可预测的替身，
 * 好让用例断言的是**融合规则本身**，而不是 OCR 归一的实现细节。
 */
class OcrFusionPolicyTest {

    private val norm: (String) -> String = { it.replace(" ", "").lowercase() }

    private fun box(l: Int, t: Int, r: Int, b: Int) = OcrBox(l, t, r, b)

    private fun host(
        ref: String = "e1",
        box: OcrBox = box(0, 0, 100, 40),
        label: String = "",
        desc: String = "",
        source: String = "a11y",
    ) = FusionHost(ref, box, label, desc, source)

    @Test
    fun `无宿主时独立成元素`() {
        val d = OcrFusionPolicy.decide(box(10, 10, 90, 30), "会话标题", emptyList(), norm)
        assertEquals(FusionDecision.Standalone, d)
    }

    @Test
    fun `中心点不在任何宿主内时独立成元素`() {
        val far = host(box = box(0, 0, 50, 20))
        val d = OcrFusionPolicy.decide(box(200, 200, 280, 220), "文件传输助手", listOf(far), norm)
        assertEquals(FusionDecision.Standalone, d)
    }

    @Test
    fun `宿主无语义时挂载上去`() {
        val empty = host(ref = "e7", box = box(0, 0, 200, 60))
        val d = OcrFusionPolicy.decide(box(10, 10, 190, 50), "文件传输助手", listOf(empty), norm)
        assertEquals(FusionDecision.Fuse("e7"), d)
    }

    /** 取最小的那个包含中心点的候选，避免整屏级容器把所有行都吞掉。 */
    @Test
    fun `多个宿主命中时取面积最小的`() {
        val big = host(ref = "big", box = box(0, 0, 1000, 400))
        val small = host(ref = "small", box = box(0, 0, 200, 60))
        val d = OcrFusionPolicy.decide(box(10, 10, 190, 50), "标题", listOf(big, small), norm)
        assertEquals(FusionDecision.Fuse("small"), d)
    }

    /** 最小的那个也太大就直接放弃，不退而求其次找次小的——次小的只会更容易误吞。 */
    @Test
    fun `最小宿主仍超过面积倍数上限时不回退到次小`() {
        val line = box(0, 0, 10, 10)                    // 面积 100
        val huge = host(ref = "huge", box = box(0, 0, 400, 400))   // 面积 160000 >> 12×100
        val d = OcrFusionPolicy.decide(line, "字", listOf(huge), norm)
        assertEquals(FusionDecision.Standalone, d)
    }

    @Test
    fun `恰好等于面积倍数上限仍可挂载`() {
        val line = box(0, 0, 10, 10)                    // 面积 100
        val edge = host(ref = "edge", box = box(0, 0, 40, 30))     // 面积 1200 == 12×100
        val d = OcrFusionPolicy.decide(line, "字", listOf(edge), norm)
        assertEquals(FusionDecision.Fuse("edge"), d)
    }

    @Test
    fun `已被先前的行挂载过的宿主不再参与`() {
        val fused = host(ref = "e3", label = "上一行", source = "fused")
        val d = OcrFusionPolicy.decide(box(10, 10, 90, 30), "这一行", listOf(fused), norm)
        assertEquals(FusionDecision.Standalone, d)
    }

    @Test
    fun `ocr 元素不能当宿主`() {
        val ocr = host(ref = "o1", source = "ocr")
        val d = OcrFusionPolicy.decide(box(10, 10, 90, 30), "文字", listOf(ocr), norm)
        assertEquals(FusionDecision.Standalone, d)
    }

    @Test
    fun `宿主已含相同内容时判为重复丢弃`() {
        val labelled = host(label = "文件传输助手")
        val d = OcrFusionPolicy.decide(box(10, 10, 90, 30), "文件传输助手", listOf(labelled), norm)
        assertEquals(FusionDecision.DropDuplicate, d)
    }

    @Test
    fun `归一化后相同也算重复`() {
        val labelled = host(label = "File Transfer")
        val d = OcrFusionPolicy.decide(box(10, 10, 90, 30), "file  transfer", listOf(labelled), norm)
        assertEquals(FusionDecision.DropDuplicate, d)
    }

    /**
     * 这条是 2026-07-19 的真机教训：vivo 充电胶囊这类**带文本的大悬浮节点**罩住页面文字时，
     * 若按"位置重叠即重复"处理，会把真正的页面内容一起吞掉（实锤：微信「选择聊天」「搜索」消失）。
     * 内容不同就必须独立落成 OCR 元素。
     */
    @Test
    fun `宿主有文本但内容不同时必须独立成元素而不是被吞掉`() {
        val capsule = host(label = "正在充电 85%")
        val d = OcrFusionPolicy.decide(box(10, 10, 90, 30), "选择聊天", listOf(capsule), norm)
        assertEquals(FusionDecision.Standalone, d)
    }

    /** 宿主文本太短时不做反向包含判定：一两个字"被包含"多半是巧合。 */
    @Test
    fun `宿主文本仅一个字时不因反向包含而丢弃`() {
        val short = host(label = "搜")
        val d = OcrFusionPolicy.decide(box(10, 10, 90, 30), "搜索聊天记录", listOf(short), norm)
        assertEquals(FusionDecision.Standalone, d)
    }

    @Test
    fun `宿主文本足够长且被行文本包含时判为重复`() {
        val part = host(label = "文件传输")
        val d = OcrFusionPolicy.decide(box(10, 10, 90, 30), "文件传输助手", listOf(part), norm)
        assertEquals(FusionDecision.DropDuplicate, d)
    }

    @Test
    fun `desc 也算宿主语义`() {
        val describedOnly = host(label = "", desc = "返回")
        val d = OcrFusionPolicy.decide(box(10, 10, 90, 30), "返回", listOf(describedOnly), norm)
        assertEquals(FusionDecision.DropDuplicate, d)
    }

    @Test
    fun `OcrBox 的 contains 是右下开区间，与 Rect 对齐`() {
        val b = box(0, 0, 10, 10)
        assertTrue(b.contains(0, 0))
        assertTrue(b.contains(9, 9))
        assertTrue(!b.contains(10, 5))
        assertTrue(!b.contains(5, 10))
        assertEquals(100L, b.area)
        assertEquals(5, b.centerX)
    }
}
