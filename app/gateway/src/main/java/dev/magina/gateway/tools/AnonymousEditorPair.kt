package dev.magina.gateway.tools

import org.json.JSONArray
import org.json.JSONObject

/** 保存查询当时的属性；同一节点稍后 refresh 的结果不能代替这份读数。 */
internal data class InputFocusReading(val node: EditorFocusNode?, val focused: Boolean?, val visible: Boolean?) {
    fun corroborates(candidate: EditorFocusNode) = node == candidate && focused == true && visible == true

    fun toJson(): JSONObject = JSONObject()
        .put("focused", focused ?: JSONObject.NULL)
        .put("visible", visible ?: JSONObject.NULL)
}

internal data class AnonymousEditor(
    val node: EditorFocusNode,
    val bounds: IntBounds,
    val focused: Boolean,
    val visible: Boolean,
    val editable: Boolean,
)

/** 两次独立查树通过节点身份比较整个集合，Binder 返回的顺序不参与判定。 */
internal data class AnonymousEditorPair(
    val fieldId: Int,
    val windowId: Int,
    val window: IntBounds,
    val service: InputFocusReading,
    val root: InputFocusReading,
    val candidates: Set<AnonymousEditor>,
) {
    val focused: AnonymousEditor? get() = candidates.singleOrNull { it.focused }

    fun hasSameScope(other: AnonymousEditorPair) = fieldId == other.fieldId && windowId == other.windowId &&
        window == other.window && candidates.map { it.node }.toSet() == other.candidates.map { it.node }.toSet()

    fun stopReason(): String? {
        if (candidates.map { it.bounds }.distinct().size == 1) return "same_bounds"
        val target = focused ?: return "focus_conflict"
        if (!service.corroborates(target.node) || !root.corroborates(target.node)) return "focus_conflict"
        if (!target.visible || !target.editable || target.bounds.isEmpty || !window.contains(target.bounds)) {
            return "target_unusable"
        }
        return null
    }

    fun receipt(phase: String, outcome: String, sample: FloatBounds? = null): JSONObject {
        val rows = JSONArray()
        for (c in candidates) {
            rows.put(JSONObject().put("focused", c.focused).put("visible", c.visible).put("editable", c.editable)
                .put("service_focus", c.node == service.node).put("root_focus", c.node == root.node)
                .put("left", c.bounds.left).put("top", c.bounds.top)
                .put("right", c.bounds.right).put("bottom", c.bounds.bottom)
                .put("matches_ime_bounds", sample?.let(c.bounds::matchesFloat) ?: JSONObject.NULL))
        }
        return JSONObject().put("phase", phase).put("outcome", outcome)
            .put("service_focus", service.toJson()).put("root_focus", root.toJson()).put("candidates", rows)
    }
}
