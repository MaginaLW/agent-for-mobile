package dev.magina.gateway.mcp

import dev.magina.gateway.a11y.P0_PREPARE_MACRO_NAME
import dev.magina.gateway.core.Level
import dev.magina.gateway.tools.MacroRunnerFactory
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
        ),
        ToolSpec(
            name = "p0_probe_region_state",
            description = "只读预检：P0 盲点候选区（微信输入栏带）当前是否视觉为空（仅 debug 验收）。" +
                "跑测前零 token 自查，挡掉「上一轮残留文字导致本轮必拒」的空跑。",
            level = Level.R,
            inputSchema = JSONObject()
                .put("type", "object")
                .put("properties", JSONObject())
                .put("required", JSONArray())
                .put("additionalProperties", false),
            handler = MacroRunnerFactory::probeRegionState,
        ),
    )
}
