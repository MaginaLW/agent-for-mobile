package dev.magina.gateway.mcp

import dev.magina.gateway.a11y.P0_PREPARE_MACRO_NAME
import dev.magina.gateway.core.Level
import dev.magina.gateway.tools.UiTools
import org.json.JSONArray
import org.json.JSONObject

internal object MacroToolCatalog {
    val tools: List<ToolSpec> = listOf(
        ToolSpec(
            name = "macro_run",
            description = "受控宏回放（仅 debug 验收白名单）。",
            level = Level.W,
            inputSchema = JSONObject()
                .put("type", "object")
                .put(
                    "properties",
                    JSONObject().put(
                        "name",
                        JSONObject().put("type", "string")
                            .put("description", "宏名")
                            .put("enum", JSONArray(listOf(P0_PREPARE_MACRO_NAME))),
                    ),
                )
                .put("required", JSONArray(listOf("name")))
                .put("additionalProperties", false),
            handler = UiTools::macroRun,
        )
    )
}
