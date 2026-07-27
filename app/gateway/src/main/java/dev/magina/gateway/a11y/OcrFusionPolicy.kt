package dev.magina.gateway.a11y

/**
 * OCR 行与 a11y 元素的融合判定（spec §5.4/§9）。
 *
 * 从 `GatewayA11yService.snapshot()` 里抽出来：那里它埋在一个 55 行的循环中间、与节点遍历和
 * JSON 组装缠在一起，改一处要在真机上验一轮。判定本身是纯的——给定一行 OCR 与当前候选宿主，
 * 输出挂载 / 丢弃 / 独立成元素，不碰 Android 对象，因此可以离线钉死。
 *
 * 几何用自带的 [OcrBox] 而不是 `android.graphics.Rect`：后者在纯 JVM 单测里是抛异常的桩
 * （本项目未配 Robolectric），用它这层就又测不了了。
 */

/** 纯几何盒。语义与 `Rect` 对齐：[contains] 右/下开区间。 */
internal data class OcrBox(val left: Int, val top: Int, val right: Int, val bottom: Int) {
    val width: Int get() = right - left
    val height: Int get() = bottom - top
    val area: Long get() = width.toLong() * height
    val centerX: Int get() = (left + right) / 2
    val centerY: Int get() = (top + bottom) / 2
    fun contains(x: Int, y: Int): Boolean = x >= left && x < right && y >= top && y < bottom
}

/** 边界转换只此一处，别在业务代码里手搓。 */
internal fun android.graphics.Rect.toOcrBox(): OcrBox = OcrBox(left, top, right, bottom)

/** 一个候选宿主：已在快照里的 a11y 元素。 */
internal data class FusionHost(
    val ref: String,
    val box: OcrBox,
    val label: String,
    val desc: String,
    /** `a11y` / `fused` / `ocr`。只有 `a11y` 才可能被挂载或判重复。 */
    val source: String,
)

internal sealed interface FusionDecision {
    /** 宿主无语义 → 把这行文字挂到它身上，元素变成可点的 `fused`。 */
    data class Fuse(val hostRef: String) : FusionDecision
    /** 宿主已有相同内容 → 这行是重复，丢弃。 */
    data object DropDuplicate : FusionDecision
    /** 挂不上 → 独立落成 `ocr` 元素（无节点，click 走坐标手势）。 */
    data object Standalone : FusionDecision
}

internal object OcrFusionPolicy {

    /**
     * 宿主面积不得超过行面积的这么多倍。
     *
     * 没有这道闸，整屏级的大容器会把每一行都吞掉。倍数是经验值：文字行与其直接容器通常在
     * 一个量级内。
     */
    const val MAX_HOST_AREA_RATIO = 12

    fun decide(
        lineBox: OcrBox,
        lineText: String,
        hosts: List<FusionHost>,
        normalize: (String) -> String,
    ): FusionDecision {
        // 只看**最小**的那个包含中心点的候选；它如果太大就直接放弃，不再退而求其次找次小的。
        // 这条"不回退"是有意的：次小的通常更大，更容易把不相干的文字吞进去。
        val host = hosts
            .filter { it.box.contains(lineBox.centerX, lineBox.centerY) }
            .minByOrNull { it.box.area }
            ?.takeIf { it.box.area <= MAX_HOST_AREA_RATIO * lineBox.area }
            ?: return FusionDecision.Standalone

        // 已被先前的行挂载过（fused）或本身就是 ocr 元素 → 不再参与，本行独立成元素。
        if (host.source != "a11y") return FusionDecision.Standalone

        val hostHasText = host.label.isNotEmpty() || host.desc.isNotEmpty()
        if (!hostHasText) return FusionDecision.Fuse(host.ref)

        // 宿主有语义时**只有内容确实相同才算重复**。放宽到"位置重叠即重复"会出事：
        // vivo 充电胶囊这类带文本的大悬浮节点罩住页面文字时，会把真正的页面内容一起吞掉
        // （2026-07-19 实锤：微信「选择聊天」「搜索」被误吞）。
        val hostNorm = normalize(host.label + host.desc)
        val lineNorm = normalize(lineText)
        val duplicate = hostNorm.contains(lineNorm) ||
            // 反向包含要求宿主文本足够长：宿主只有一两个字时，"被包含"多半是巧合而不是重复。
            (lineNorm.contains(hostNorm) && hostNorm.length >= 2)
        return if (duplicate) FusionDecision.DropDuplicate else FusionDecision.Standalone
    }
}
