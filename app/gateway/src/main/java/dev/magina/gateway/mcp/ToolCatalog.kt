package dev.magina.gateway.mcp

import dev.magina.gateway.Gateway
import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.GatewayError
import dev.magina.gateway.core.Level
import dev.magina.gateway.macro.MacroEngine
import dev.magina.gateway.tools.IntentTools
import dev.magina.gateway.tools.NotificationTools
import dev.magina.gateway.tools.SystemTools
import dev.magina.gateway.tools.UiTools
import org.json.JSONArray
import org.json.JSONObject

class ToolSpec(
    val name: String,
    val description: String,
    val level: Level,
    val inputSchema: JSONObject,
    val handler: (JSONObject) -> JSONObject,
)

/** 调用结果：文本信封 + 可选图片（screen_capture 用 MCP image content 回图，不塞 JSON）。 */
class ToolResult(val envelope: JSONObject, val imageBase64: String? = null, val imageMime: String = "image/png")

/**
 * MCP 工具目录与通道映射。
 * 拆分自原 ToolRegistry，专注于工具元数据声明、黑名单前景放行集与通道归属。
 */
internal object ToolCatalog {

    private fun prop(type: String, desc: String, enum: List<String>? = null): JSONObject =
        JSONObject().put("type", type).put("description", desc)
            .apply { enum?.let { put("enum", JSONArray(it)) } }

    private fun schema(required: List<String>, vararg props: Pair<String, JSONObject>): JSONObject =
        JSONObject()
            .put("type", "object")
            .put("properties", JSONObject().apply { props.forEach { (k, v) -> put(k, v) } })
            .put("required", JSONArray(required))

    private fun gatedOnly(name: String): (JSONObject) -> JSONObject = {
        throw GatewayError(ErrorCode.E_INTERNAL, "$name 只能由统一安全门执行")
    }

    val baseTools: List<ToolSpec> = listOf(
        // ---------- L1 系统层 ----------
        ToolSpec(
            "device_info", "设备与网关能力概览（分辨率/系统/电量/能力位）。任务开场调用一次。",
            Level.R, schema(emptyList()),
        ) { SystemTools.deviceInfo() },
        ToolSpec(
            "system_get_state", "读系统状态（白名单 key）。返回值带真值源 source。",
            Level.R,
            schema(
                listOf("key"),
                "key" to prop("string", "状态键", listOf("bluetooth", "wifi", "airplane", "battery", "network", "screen", "volume", "brightness")),
            ),
        ) { SystemTools.getState(it.getString("key")) },
        ToolSpec(
            "system_set_state", "改系统状态。M1a 仅 volume 可写；蓝牙/WiFi 等待 Shizuku 通道（M1b），当前会返回 UI 兜底路径。",
            Level.W,
            schema(
                listOf("key", "value"),
                "key" to prop("string", "状态键"),
                "value" to prop("string", "目标值，如 on/off/整数"),
            ),
        ) { SystemTools.setState(it.getString("key"), it.getString("value")) },
        ToolSpec(
            "system_verify_state", "用独立真值源复核状态（M0 教训：单一返回不可信）。",
            Level.R,
            schema(
                listOf("key", "expected"),
                "key" to prop("string", "状态键"),
                "expected" to prop("string", "期望值"),
            ),
        ) { SystemTools.verifyState(it.getString("key"), it.getString("expected")) },
        ToolSpec(
            "foreground_app",
            "当前前台 app 与 Activity，并附前台身份诊断：foreground_reason、窗口列表（含 root_package）、最近窗口事件处置。" +
                "任何工具返回 foreground_known=false 时先调它取证。",
            Level.R, schema(emptyList()),
        ) {
            SystemTools.foregroundApp()
        },
        ToolSpec("keyboard_state", "读取软键盘可见性与高度。", Level.R, schema(emptyList(),
            "probe_editor_origin" to prop("boolean", "可选。用已在位的网关输入法查询当前编辑器的屏幕原点；原点只供诊断。"),
            "probe_editor_bounds" to prop("boolean", "可选。核对输入焦点和输入法观察到的编辑框四边。横屏命中两个无名候选时报告各自的焦点属性和四边。仅供诊断，与原点/光标锚点查询分次使用。"),
            "probe_cursor_anchor" to prop("boolean", "可选。绕开前置无障碍焦点闸门，直接向当前输入连接请求 CursorAnchorInfo（2参过滤优先、退回1参），结合同包可见应用窗口做互不重叠归属，并附脱敏契约与无短路节点遥测。仅供只读诊断，与原点/四边查询分次使用。"),
        )) {
            SystemTools.keyboardState(
                probeEditorOrigin = it.opt("probe_editor_origin") == true,
                probeEditorBounds = it.opt("probe_editor_bounds") == true,
                probeCursorAnchor = it.opt("probe_cursor_anchor") == true,
            )
        },
        ToolSpec(
            "app_launch", "按别名或包名启动 app，执行后验前台。",
            Level.W, schema(listOf("name"), "name" to prop("string", "app 别名（微信/京东…）或包名")),
        ) { SystemTools.appLaunch(it.getString("name")) },
        ToolSpec(
            "clipboard", "剪贴板读写。读取需本 app 为默认 IME（Android 10+ 限制）。",
            Level.W,
            schema(
                listOf("op"),
                "op" to prop("string", "get 或 set", listOf("get", "set")),
                "text" to prop("string", "set 时的内容"),
            ),
        ) { SystemTools.clipboard(it.getString("op"), it.optString("text")) },
        ToolSpec(
            "media_query", "查媒体库（MediaStore 直读，跳过相册 UI 导航——任务 4 捷径）。",
            Level.R,
            schema(
                listOf("type"),
                "type" to prop("string", "image 或 screenshot", listOf("image", "screenshot")),
                "album" to prop("string", "相册名（可选）"),
                "limit" to prop("integer", "条数，默认 5"),
            ),
        ) { SystemTools.mediaQuery(it.getString("type"), it.optString("album").ifEmpty { null }, it.optInt("limit", 5)) },
        ToolSpec(
            "skillpack_lookup",
            "查询网关内置技能包（app 别名、已实测/未实测深链前缀、系统设置不可靠 action 提示与只读前置守卫）。执行非微信日常只读或系统设置操作前按需调用。",
            Level.R,
            schema(
                emptyList(),
                "app" to prop("string", "可选：app 别名（小红书/京东/淘宝/设置…）、包名或 URI 前缀；留空返回总览"),
            ),
        ) { Gateway.skills.lookupForBrain(it.optString("app").ifEmpty { null }) },
        ToolSpec(
            "skill_macro_list",
            "列出网关内置的声明式生产宏（含用途、参数约束与验证状态）。高频任务开始前可按需查询。",
            Level.R,
            schema(emptyList()),
        ) { Gateway.macros.listForBrain() },
        ToolSpec(
            "skill_macro_exec",
            "执行已注册的声明式生产宏。每步均走统一安全门与 ConfirmOverlay；当 data.status=\"completed\" 时直接返回 data.final_snapshot 与 ctx.app，遇到非安全阻塞时返回 data.status=\"handoff_required\" 交大脑断点接管。",
            Level.W,
            schema(
                listOf("name"),
                "name" to prop("string", "生产宏 id（来自 skill_macro_list）"),
                "params" to prop("object", "声明的宏参数键值对（可选）"),
            ),
        ) { args ->
            MacroEngine(
                catalog = Gateway.macros,
                isBlockedApp = Gateway.skills::isBlockedApp,
                loginWallKeywordsForPackage = { pkg ->
                    Gateway.skills.appGuides[pkg]?.loginWallKeywords.orEmpty()
                },
                stepExecutor = { toolName, stepArgs ->
                    ToolRegistry.callFromMacro(toolName, stepArgs).envelope
                },
            ).run(args)
        },

        // ---------- L2 意图层 ----------
        ToolSpec(
            "open_uri", "打开深链/URL。命中技能包注册表时执行后验前台，验不上报 E_VERIFY_FAIL（附 UI 兜底路径）。",
            Level.W, schema(listOf("uri"), "uri" to prop("string", "深链或 https URL，参数自行 urlencode")),
        ) { IntentTools.openUri(it.getString("uri")) },
        ToolSpec(
            "intent_send", "发送白名单 Intent（VIEW/SEND/SENDTO/MAIN/android.settings.*）。指定 package/component 后验证前台落地，验不上报 E_VERIFY_FAIL；无目标仅报告已分派、未验证。组件只接受技能包注册项。",
            Level.W,
            schema(
                listOf("action"),
                "action" to prop("string", "Intent action 全名"),
                "uri" to prop("string", "data URI（可选）"),
                "extras" to prop("object", "字符串 extras（可选）"),
                "package" to prop("string", "定向包名/别名（可选）"),
                "component" to prop("string", "显式组件类名（须已注册，可选）"),
            ),
        ) {
            IntentTools.intentSend(
                it.getString("action"), it.optString("uri").ifEmpty { null },
                it.optJSONObject("extras"), it.optString("package").ifEmpty { null },
                it.optString("component").ifEmpty { null },
            )
        },
        ToolSpec(
            "share_text", "系统分享文本。target 给包名/别名可定向。",
            Level.W,
            schema(
                listOf("text"),
                "text" to prop("string", "要分享的文本"),
                "target" to prop("string", "目标 app（可选）"),
            ),
        ) { IntentTools.shareText(it.getString("text"), it.optString("target").ifEmpty { null }) },
        ToolSpec(
            "share_file", "系统分享文件（uri 来自 media_query）。三级降级：直达组件→定向→系统面板。",
            Level.W,
            schema(
                listOf("uri", "mime"),
                "uri" to prop("string", "content:// URI"),
                "mime" to prop("string", "如 image/*"),
                "target" to prop("string", "目标 app（可选）"),
            ),
        ) { IntentTools.shareFile(it.getString("uri"), it.getString("mime"), it.optString("target").ifEmpty { null }) },

        // ---------- L3 通知层（严格只读） ----------
        ToolSpec(
            "notifications_list",
            "读取当前状态栏活动通知只读快照（L3）。默认隔离网关自身审批通知与敏感黑名单应用；支持按包名/别名过滤与 limit 截断。",
            Level.R,
            schema(
                emptyList(),
                "package" to prop("string", "可选：按 app 别名或包名过滤"),
                "limit" to prop("integer", "可选：返回条数上限（1..50，默认 20）"),
            ),
        ) { NotificationTools.listNotifications(it) },

        // ---------- L4 UI 层 ----------
        ToolSpec(
            "ui_snapshot", "当前页面语义元素列表（带 revision；树空/稀疏自动融合 OCR，source=a11y|ocr|fused；ref 供后续操作寻址）。首选感知工具。",
            Level.R,
            schema(
                emptyList(),
                "scope" to prop("string", "interactive=可交互+短文本（默认）；full=含长文本供阅读", listOf("interactive", "full")),
            ),
        ) { UiTools.uiSnapshot(it.optString("scope", "interactive")) },
        ToolSpec(
            "ui_find", "按文本/角色/描述找元素；scroll_search=true 时网关自行滚动查找（≤3 屏）。",
            Level.R,
            schema(
                emptyList(),
                "text" to prop("string", "文本包含匹配"),
                "role" to prop("string", "button/input/text/list/switch/icon_button"),
                "desc" to prop("string", "contentDescription 包含匹配"),
                "scroll_search" to prop("boolean", "找不到时自动滚动，默认 false"),
            ),
        ) {
            UiTools.uiFind(
                it.optString("text").ifEmpty { null }, it.optString("role").ifEmpty { null },
                it.optString("desc").ifEmpty { null }, it.optBoolean("scroll_search", false),
            )
        },
        ToolSpec(
            "ui_action", "对 ref 执行动作。点击前二次校验；OCR 元素 click/long_click 走坐标手势；危险目标由统一安全门确认。不接受裸坐标。",
            Level.W,
            schema(
                listOf("ref", "action"),
                "ref" to prop("string", "来自最近一次 ui_snapshot/ui_find"),
                "action" to prop("string", "动作", listOf("click", "long_click", "set_text", "scroll", "focus", "dismiss")),
                "text" to prop("string", "set_text 用"),
                "direction" to prop("string", "scroll 用：forward/backward"),
            ),
            handler = gatedOnly("ui_action"),
        ),
        ToolSpec(
            "type_text", "输入文本（中文关键路径）：SET_TEXT→自有 IME 字面注入，内置读回验证（树空场景 OCR 读回）。永不使用剪贴板机制。",
            Level.W,
            schema(
                listOf("text"),
                "text" to prop("string", "字面文本（空格/换行/标点原样注入）"),
                "ref" to prop("string", "目标输入框 ref；缺省=当前焦点"),
                "mode" to prop("string", "append（默认）或 replace（精确覆盖）", listOf("append", "replace")),
            ),
        ) { UiTools.typeText(it.getString("text"), it.optString("ref").ifEmpty { null }, it.optString("mode", "append")) },
        ToolSpec(
            "press_key", "全局键/编辑键。",
            Level.W,
            schema(
                listOf("key"),
                "key" to prop("string", "按键", listOf("back", "home", "recents", "notifications", "enter", "del")),
            ),
            handler = gatedOnly("press_key"),
        ),
        ToolSpec(
            "wait_for", "等待条件（网关内轮询，不烧大脑轮次）。",
            Level.R,
            schema(
                listOf("condition"),
                "condition" to prop(
                    "string", "条件",
                    listOf("text_appears", "text_gone", "app_foreground", "keyboard_shown", "keyboard_hidden", "idle"),
                ),
                "text" to prop("string", "text_* 条件的文本"),
                "package" to prop("string", "app_foreground 的包名"),
                "quiet_ms" to prop("integer", "idle 的静默阈值，默认 800"),
                "timeout_ms" to prop("integer", "超时，默认 8000，上限 30000"),
            ),
        ) {
            UiTools.waitFor(it.getString("condition"), it, it.optLong("timeout_ms", 8000))
        },

        // ---------- L6 受控兜底 ----------
        ToolSpec(
            "screen_capture", "受控原图（最后兜底）：reason 必填进审计；给 ref/region 只回裁剪图。结构化通道能用时禁止调用。",
            Level.R,
            schema(
                listOf("reason"),
                "reason" to prop(
                    "string", "调用理由",
                    listOf("low_confidence", "unknown_page", "icon_unrecognized", "layout_changed", "risk_review"),
                ),
                "ref" to prop("string", "只截该元素区域（优先）"),
                "region" to prop("array", "[l,t,r,b] 物理像素裁剪区"),
            ),
        ) { UiTools.screenCapture(it.getString("reason"), it.optString("ref").ifEmpty { null }, it.optJSONArray("region")) },
    )

    /** 敏感 app 前台时仍放行的工具（撤离、纯感知与静态技能包/宏目录查询）；press_key 另限安全撤离键。 */
    val BLOCKED_APP_ALLOWED = setOf(
        "device_info", "foreground_app", "keyboard_state", "press_key", "app_launch", "wait_for",
        "skillpack_lookup", "skill_macro_list",
    )

    fun listToolsJson(tools: List<ToolSpec>): JSONArray {
        val arr = JSONArray()
        tools.forEach {
            arr.put(
                JSONObject()
                    .put("name", it.name)
                    .put("description", "[${it.level}] ${it.description}")
                    .put("inputSchema", it.inputSchema),
            )
        }
        return arr
    }

    fun channelOf(name: String): String = when {
        name.startsWith("ui_") || name in setOf("type_text", "press_key", "wait_for") -> "a11y"
        name.startsWith("system_") || name in setOf(
            "device_info", "clipboard", "media_query", "foreground_app", "keyboard_state",
            "skillpack_lookup", "skill_macro_list",
        ) -> "api"
        name in setOf("open_uri", "intent_send", "share_text", "share_file", "app_launch") -> "intent"
        name == "notifications_list" -> "notif"
        name == "screen_capture" -> "vision"
        name == "skill_macro_exec" -> "macro"
        // 受控宏走 a11y + IME 复合通道；此前落到空串，写出的审计行 channel 为空，
        // 而审计契约要求每行都有非空通道（2026-07-26：审计一能读到就立刻被这条卡住）。
        name == "macro_run" -> "a11y"
        else -> "tool"
    }

    fun blockedAppAllows(name: String, args: JSONObject): Boolean = when {
        name !in BLOCKED_APP_ALLOWED -> false
        name == "press_key" -> args.optString("key") in setOf("back", "home", "recents")
        else -> true
    }
}
