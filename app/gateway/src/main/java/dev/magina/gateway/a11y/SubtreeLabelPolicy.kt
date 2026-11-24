package dev.magina.gateway.a11y

import android.view.accessibility.AccessibilityNodeInfo

/**
 * 纯值树节点摘要，供严格子树标签聚合与离线 JVM 单测复用。
 * 不持有父/兄弟指针，从结构上保证绝不跨兄弟节点借用文本。
 */
internal data class SubtreeLabelNode(
    val text: String = "",
    val desc: String = "",
    val isVisibleToUser: Boolean = true,
    val isClickable: Boolean = false,
    val isLongClickable: Boolean = false,
    val isCheckable: Boolean = false,
    val isEditable: Boolean = false,
    val children: List<SubtreeLabelNode> = emptyList(),
)

/**
 * 严格子树标签聚合策略（类似 TalkBack 容器语义，fail-closed）。
 *
 * 仅当候选节点自身可见、可点击或可长按且非可编辑、自身 `text` 与 `desc` 均为空、
 * 且子树内不存在任何嵌套可交互子节点（clickable / longClickable / checkable / editable）时，
 * 才按有限深度与长度聚合可见非交互子孙节点的 `text`/`desc`。
 */
internal object SubtreeLabelPolicy {
    const val DEFAULT_MAX_DEPTH = 6
    const val DEFAULT_MAX_LENGTH = 120
    const val DEFAULT_MAX_SCAN_DEPTH = 24
    const val DEFAULT_MAX_SCAN_NODES = 64

    fun isCandidate(node: SubtreeLabelNode): Boolean =
        node.isVisibleToUser &&
            (node.isClickable || node.isLongClickable) &&
            !node.isEditable &&
            node.text.isBlank() &&
            node.desc.isBlank()

    fun aggregate(
        node: SubtreeLabelNode,
        maxDepth: Int = DEFAULT_MAX_DEPTH,
        maxLength: Int = DEFAULT_MAX_LENGTH,
        maxScanDepth: Int = DEFAULT_MAX_SCAN_DEPTH,
        maxScanNodes: Int = DEFAULT_MAX_SCAN_NODES,
    ): String = aggregateWith(
        root = node,
        textOf = { it.text },
        descOf = { it.desc },
        isVisible = { it.isVisibleToUser },
        isClickable = { it.isClickable },
        isLongClickable = { it.isLongClickable },
        isCheckable = { it.isCheckable },
        isEditable = { it.isEditable },
        childCount = { it.children.size },
        childAt = { n, idx -> n.children[idx] },
        maxDepth = maxDepth,
        maxLength = maxLength,
        maxScanDepth = maxScanDepth,
        maxScanNodes = maxScanNodes,
    )

    fun aggregate(
        node: AccessibilityNodeInfo,
        maxDepth: Int = DEFAULT_MAX_DEPTH,
        maxLength: Int = DEFAULT_MAX_LENGTH,
        maxScanDepth: Int = DEFAULT_MAX_SCAN_DEPTH,
        maxScanNodes: Int = DEFAULT_MAX_SCAN_NODES,
    ): String = aggregateWith(
        root = node,
        textOf = { it.text?.toString().orEmpty() },
        descOf = { it.contentDescription?.toString().orEmpty() },
        isVisible = { it.isVisibleToUser },
        isClickable = { it.isClickable },
        isLongClickable = { it.isLongClickable },
        isCheckable = { it.isCheckable },
        isEditable = { it.isEditable },
        childCount = { it.childCount },
        childAt = { n, idx -> n.getChild(idx) },
        maxDepth = maxDepth,
        maxLength = maxLength,
        maxScanDepth = maxScanDepth,
        maxScanNodes = maxScanNodes,
    )

    private fun <T> aggregateWith(
        root: T,
        textOf: (T) -> String,
        descOf: (T) -> String,
        isVisible: (T) -> Boolean,
        isClickable: (T) -> Boolean,
        isLongClickable: (T) -> Boolean,
        isCheckable: (T) -> Boolean,
        isEditable: (T) -> Boolean,
        childCount: (T) -> Int,
        childAt: (T, Int) -> T?,
        maxDepth: Int,
        maxLength: Int,
        maxScanDepth: Int,
        maxScanNodes: Int,
    ): String {
        val eligibleRoot = isVisible(root) &&
            (isClickable(root) || isLongClickable(root)) &&
            !isEditable(root) &&
            textOf(root).isBlank() &&
            descOf(root).isBlank()
        if (!eligibleRoot || maxDepth <= 0 || maxLength <= 0 || maxScanNodes <= 0) return ""

        val scanDepthLimit = maxOf(maxScanDepth, maxDepth)
        val parts = ArrayList<String>()
        var visitedNodes = 0
        var rejected = false

        fun visitDescendant(cur: T, depth: Int, ancestorVisible: Boolean) {
            if (rejected) return
            visitedNodes += 1
            if (visitedNodes > maxScanNodes || depth > scanDepthLimit) {
                rejected = true
                return
            }
            if (isClickable(cur) || isLongClickable(cur) || isCheckable(cur) || isEditable(cur)) {
                rejected = true
                return
            }
            val effectiveVisible = ancestorVisible && isVisible(cur)
            if (effectiveVisible && depth <= maxDepth) {
                val t = textOf(cur).trim()
                val d = descOf(cur).trim()
                if (t.isNotEmpty() && t !in parts) parts.add(t)
                if (d.isNotEmpty() && d !in parts) parts.add(d)
            }
            val childrenTotal = childCount(cur)
            for (i in 0 until childrenTotal) {
                val child = childAt(cur, i) ?: continue
                visitDescendant(child, depth + 1, effectiveVisible)
                if (rejected) return
            }
        }

        val rootChildren = childCount(root)
        for (i in 0 until rootChildren) {
            val child = childAt(root, i) ?: continue
            visitDescendant(child, depth = 1, ancestorVisible = true)
            if (rejected) return ""
        }

        if (parts.isEmpty()) return ""
        val joined = parts.joinToString(" ")
        return if (joined.length <= maxLength) joined else joined.take(maxLength).trimEnd()
    }
}
