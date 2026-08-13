package dev.magina.gateway.a11y

/** 输入栏裁剪里的一条 OCR 候选；纯值对象，便于 JVM 离线固定聚合边界。 */
internal data class InputBarOcrLine(
    val text: String,
    val confidence: Float,
    val box: OcrBox,
)

/**
 * 输入栏 OCR 行到单个读回串的聚合边界。
 *
 * OCR 会对原图和增强图各识别一次；同一物理文字若只差标点，通用 OCR 合并层会保留两行。
 * 这里只折叠“几何上是同一行、语义上也是包含关系”的替代识别。无法同时证明这两点时宁可保留，
 * 让下游内容长度门继续 fail-closed。折叠时也绝不让 confidence 抹掉更长的内容：优先保留归一后
 * 信息更多的候选，只有归一结果等长（也就相同）时才按 confidence 选。
 */
internal object InputBarOcrReadbackPolicy {
    private const val SAME_PHYSICAL_LINE_IOU = 0.5

    private data class Candidate(
        val line: InputBarOcrLine,
        val normalized: String,
    )

    fun compose(
        lines: List<InputBarOcrLine>,
        normalize: (String) -> String,
    ): String? {
        if (lines.isEmpty()) return null

        val order = compareBy<InputBarOcrLine> { it.box.top }
            .thenBy { it.box.left }
            .thenBy { it.box.bottom }
            .thenBy { it.box.right }
            .thenBy { it.text }
            .thenByDescending { it.confidence }
        val candidates = lines.sortedWith(order).map {
            Candidate(line = it, normalized = normalize(it.text))
        }
        val visited = BooleanArray(candidates.size)
        val retained = mutableListOf<InputBarOcrLine>()

        for (start in candidates.indices) {
            if (visited[start]) continue
            val component = mutableListOf(start)
            visited[start] = true
            var cursor = 0
            while (cursor < component.size) {
                val current = component[cursor++]
                for (neighbor in candidates.indices) {
                    if (!visited[neighbor] && samePhysicalLine(candidates[current], candidates[neighbor])) {
                        visited[neighbor] = true
                        component += neighbor
                    }
                }
            }

            // “像同一行”不是传递关系。A↔桥、桥↔C 并不能证明 A↔C；这种歧义分量全部保留，
            // 避免一个高置信桥接候选吞掉两处真实重复内容。
            val isClique = component.indices.all { left ->
                (left + 1 until component.size).all { right ->
                    samePhysicalLine(candidates[component[left]], candidates[component[right]])
                }
            }
            if (!isClique) {
                retained += component.map { candidates[it].line }
                continue
            }

            retained += component
                .map { candidates[it] }
                .maxWithOrNull(
                    compareBy<Candidate> { it.normalized.length }
                        .thenBy { it.line.confidence }
                        .thenBy { it.line.text.length }
                        .thenBy { it.line.text },
                )!!
                .line
        }

        return retained
            .sortedWith(order)
            .joinToString(" ") { it.text }
            .takeIf { it.isNotEmpty() }
    }

    private fun samePhysicalLine(
        first: Candidate,
        second: Candidate,
    ): Boolean {
        if (intersectionOverUnion(first.line.box, second.line.box) < SAME_PHYSICAL_LINE_IOU) return false

        if (first.normalized.isEmpty() || second.normalized.isEmpty()) return false
        if (minOf(first.normalized.length, second.normalized.length) < 2) return false
        return first.normalized.contains(second.normalized) || second.normalized.contains(first.normalized)
    }

    private fun intersectionOverUnion(first: OcrBox, second: OcrBox): Double {
        if (first.width <= 0 || first.height <= 0 || second.width <= 0 || second.height <= 0) {
            return 0.0
        }
        val intersectionWidth =
            (minOf(first.right, second.right) - maxOf(first.left, second.left)).coerceAtLeast(0)
        val intersectionHeight =
            (minOf(first.bottom, second.bottom) - maxOf(first.top, second.top)).coerceAtLeast(0)
        val intersectionArea = intersectionWidth.toLong() * intersectionHeight
        if (intersectionArea == 0L) return 0.0
        val unionArea = first.area + second.area - intersectionArea
        return if (unionArea > 0L) intersectionArea.toDouble() / unionArea else 0.0
    }
}
