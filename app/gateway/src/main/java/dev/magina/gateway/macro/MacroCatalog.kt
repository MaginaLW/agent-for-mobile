package dev.magina.gateway.macro

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/**
 * 生产声明式宏目录（数据源 `assets/skillpack/macros/`）。
 * 与 debug 专属 P0 验收宏（P0WeChatPrepareMacro）完全隔离。
 */
class MacroCatalog internal constructor(
    rawMacros: List<JSONObject>,
    isBlockedApp: (String?) -> Boolean,
) {
    constructor(context: Context, isBlockedApp: (String?) -> Boolean) : this(
        rawMacros = loadFromAssets(context),
        isBlockedApp = isBlockedApp,
    )

    internal val macrosById: Map<String, MacroSpec>

    init {
        val map = LinkedHashMap<String, MacroSpec>()
        for (raw in rawMacros) {
            val parsed = MacroContract.parseMacroSpec(raw, isBlockedApp)
            require(!map.containsKey(parsed.id)) { "存在重复宏定义：${parsed.id}" }
            map[parsed.id] = parsed
        }
        macrosById = map
    }

    internal fun find(id: String): MacroSpec? = macrosById[id]

    internal fun all(): List<MacroSpec> = macrosById.values.toList()

    fun listForBrain(): JSONObject {
        val items = JSONArray()
        for (spec in macrosById.values) {
            val paramsObj = JSONObject()
            spec.params.values.forEach { p ->
                paramsObj.put(
                    p.name,
                    JSONObject()
                        .put("type", p.type)
                        .put("required", p.required)
                        .put("min_length", p.minLength)
                        .put("max_length", p.maxLength),
                )
            }
            items.put(
                JSONObject()
                    .put("id", spec.id)
                    .put("version", spec.version)
                    .put("app", spec.app)
                    .put("expect_package", spec.expectPackage)
                    .put("description", spec.description)
                    .put("readonly", spec.readonly)
                    .put("verified", spec.verified)
                    .put("status", if (spec.verified.isNotEmpty()) "verified" else "candidate_unverified")
                    .put("params", paramsObj)
                    .put("step_count", spec.steps.size),
            )
        }
        return JSONObject()
            .put("count", items.length())
            .put("macros", items)
    }

    private companion object {
        fun loadFromAssets(context: Context): List<JSONObject> {
            val indexText = context.assets.open("skillpack/macros/index.json").readBytes().decodeToString()
            val files = JSONObject(indexText).getJSONArray("files")
            require(files.length() > 0) { "skillpack/macros/index.json files 不得为空" }
            return (0 until files.length()).map { idx ->
                val fileName = files.getString(idx).trim()
                require(fileName.isNotEmpty() && !fileName.contains('/') && !fileName.contains('\\')) {
                    "非法宏文件名：$fileName"
                }
                val body = context.assets.open("skillpack/macros/$fileName").readBytes().decodeToString()
                JSONObject(body)
            }
        }
    }
}
