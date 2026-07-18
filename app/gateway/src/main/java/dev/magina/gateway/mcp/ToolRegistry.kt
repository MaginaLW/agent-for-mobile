package dev.magina.gateway.mcp

import android.os.SystemClock
import dev.magina.gateway.Gateway
import dev.magina.gateway.a11y.GatewayA11yService
import dev.magina.gateway.core.Envelope
import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.GatewayError
import dev.magina.gateway.tools.IntentTools
import dev.magina.gateway.tools.SystemTools
import dev.magina.gateway.tools.UiTools
import org.json.JSONArray
import org.json.JSONObject

/** 动作分级（spec §5）：R 只读 / W 普通写 / D 危险（工具级默认值；目标级升级在工具内部做）。 */
enum class Level { R, W, D }

class ToolSpec(
    val name: String,
    val description: String,
    val level: Level,
    val inputSchema: JSONObject,
    val handler: (JSONObject) -> JSONObject,
)

/** 调用结果：文本信封 + 可选图片（screen_capture 用 MCP image content 回图，不塞 JSON）。 */
class ToolResult(val envelope: JSONObject, val imageBase64: String? = null, val imageMime: String = "image/png")

object ToolRegistry {

    // ---- schema 构造小工具 ----
    private fun prop(type: String, desc: String, enum: List<String>? = null): JSONObject =
        JSONObject().put("type", type).put("description", desc)
            .apply { enum?.let { put("enum", JSONArray(it)) } }

    private fun schema(required: List<String>, vararg props: Pair<String, JSONObject>): JSONObject =
        JSONObject()
            .put("type", "object")
            .put("properties", JSONObject().apply { props.forEach { (k, v) -> put(k, v) } })
            .put("required", JSONArray(required))

    private fun stub(msg: String, fallback: String): (JSONObject) -> JSONObject = {
        throw GatewayError(ErrorCode.E_CHANNEL_DOWN, msg, fallback = fallback)
    }

    val tools: List<ToolSpec> = listOf(
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
        ToolSpec("foreground_app", "当前前台 app 与 Activity。", Level.R, schema(emptyList())) {
            SystemTools.foregroundApp()
        },
        ToolSpec("keyboard_state", "软键盘可见性与高度（坐标错位主因的感知面）。", Level.R, schema(emptyList())) {
            SystemTools.keyboardState()
        },
        ToolSpec(
            "app_launch", "按别名或包名启动 app，执行后验前台。",
            Level.W, schema(listOf("name"), "name" to prop("string", "app 别名（微信/京东…）或包名")),
        ) { SystemTools.appLaunch(it.getString("name")) },
        ToolSpec(
            "app_stop", "强停 app（Shizuku 通道，M1b）。",
            Level.W, schema(listOf("package"), "package" to prop("string", "包名")),
        ) { SystemTools.appStop(it.getString("package")) },
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

        // ---------- L2 意图层 ----------
        ToolSpec(
            "open_uri", "打开深链/URL。命中技能包注册表时执行后验前台，验不上报 E_VERIFY_FAIL（附 UI 兜底路径）。",
            Level.W, schema(listOf("uri"), "uri" to prop("string", "深链或 https URL，参数自行 urlencode")),
        ) { IntentTools.openUri(it.getString("uri")) },
        ToolSpec(
            "intent_send", "发送白名单 Intent（VIEW/SEND/SENDTO/MAIN/android.settings.*）。组件只接受技能包注册项。",
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

        // ---------- L3 通知层（M1b 占位） ----------
        ToolSpec(
            "notifications_list", "列当前通知（M1b：NotificationListener）。",
            Level.R, schema(emptyList()),
            handler = stub("通知层在 M1b 实现", "打开目标 app 走 UI 读取"),
        ),
        ToolSpec(
            "notification_reply", "通知内直接回复（M1b；危险级=对外发送）。",
            Level.D,
            schema(listOf("id", "text"), "id" to prop("string", "通知 id"), "text" to prop("string", "回复内容")),
            handler = stub("通知层在 M1b 实现", "打开目标 app 走 UI 回复"),
        ),

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
            "ui_diff", "自某 revision 以来的元素增删改（M1b）。",
            Level.R, schema(listOf("since_revision"), "since_revision" to prop("integer", "上次 snapshot 的 revision")),
        ) { UiTools.uiDiff(it.getLong("since_revision")) },
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
            "ui_action", "对 ref 执行动作。点击前二次校验（文本变了拒执行）；OCR 元素 click/long_click 走坐标手势；命中危险词自动弹带内确认。不接受裸坐标。",
            Level.W,
            schema(
                listOf("ref", "action"),
                "ref" to prop("string", "来自最近一次 ui_snapshot/ui_find"),
                "action" to prop("string", "动作", listOf("click", "long_click", "set_text", "scroll", "focus", "dismiss")),
                "text" to prop("string", "set_text 用"),
                "direction" to prop("string", "scroll 用：forward/backward"),
            ),
        ) {
            val params = JSONObject()
                .put("text", it.optString("text"))
                .put("direction", it.optString("direction", "forward"))
            UiTools.uiAction(it.getString("ref"), it.getString("action"), params)
        },
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
        ) { UiTools.pressKey(it.getString("key")) },
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

        // ---------- 确认与宏 ----------
        ToolSpec(
            "confirm", "危险动作带内确认：悬浮窗卡片等人点头（60s 超时→按 [AWAIT_CONFIRM] 走带外）。",
            Level.R,
            schema(listOf("action_desc"), "action_desc" to prop("string", "一句话说清将要执行什么")),
        ) { UiTools.confirm(it.getString("action_desc")) },
        ToolSpec(
            "macro_run", "宏回放（M3 占位）。",
            Level.W, schema(listOf("name"), "name" to prop("string", "宏名")),
        ) { UiTools.macroRun(it.getString("name")) },
    )

    private val byName = tools.associateBy { it.name }

    /** 敏感 app 前台时仍放行的工具（撤离与纯感知）。 */
    private val BLOCKED_APP_ALLOWED = setOf(
        "device_info", "foreground_app", "keyboard_state", "press_key", "app_launch", "wait_for",
    )

    fun listToolsJson(): JSONArray {
        val arr = JSONArray()
        tools.forEach {
            arr.put(
                JSONObject()
                    .put("name", it.name)
                    .put("description", "[${it.level}] ${it.description}")
                    .put("inputSchema", it.inputSchema)
            )
        }
        return arr
    }

    fun call(name: String, args: JSONObject): ToolResult {
        val auditId = Gateway.audit.nextId()
        val start = SystemClock.elapsedRealtime()
        val spec = byName[name]
        val fingerprint = args.toString()

        fun ctxNow(): JSONObject =
            GatewayA11yService.instance?.ctx(Gateway.caps())
                ?: JSONObject().put("app", "").put("revision", -1)
                    .put("keyboard", JSONObject().put("visible", false).put("height", 0))
                    .put("caps", JSONArray(Gateway.caps()))
                    .put("note", "a11y 未开启，ctx 降级")

        fun finish(env: JSONObject, code: String, channel: String, image: String? = null): ToolResult {
            Gateway.audit.write(auditId, name, args, code, channel, SystemClock.elapsedRealtime() - start)
            return ToolResult(env, image)
        }

        if (spec == null) {
            val e = GatewayError(ErrorCode.E_INVALID_ARG, "未知工具：$name")
            return finish(Envelope.err(e, ctxNow(), auditId), e.code.name, "")
        }

        return try {
            // 敏感 app 黑名单闸（spec §10）：银行类前台时只许感知与撤离
            val fg = GatewayA11yService.instance?.foregroundPackage()
            if (Gateway.skills.isBlockedApp(fg) && name !in BLOCKED_APP_ALLOWED) {
                throw GatewayError(
                    ErrorCode.E_BLOCKED, "前台是敏感 app（$fg），默认拒绝一切读写",
                    fallback = "press_key(home) 离开后继续任务，并在报告中说明",
                )
            }
            Gateway.retryGuard.checkAllowed(name, fingerprint)
            val data = spec.handler(args)

            // screen_capture 的图走 MCP image content，不塞 JSON 信封（token 考量）
            var image: String? = null
            if (name == "screen_capture") {
                image = data.optString("base64").ifEmpty { null }
                data.remove("base64")
            }
            Gateway.retryGuard.recordSuccess(name, fingerprint)
            finish(Envelope.ok(data, ctxNow(), auditId), "OK", channelOf(name), image)
        } catch (e: GatewayError) {
            if (e.code != ErrorCode.E_RETRY_EXHAUSTED && e.code != ErrorCode.E_CONFIRM_TIMEOUT) {
                Gateway.retryGuard.recordFailure(name, fingerprint)
            }
            finish(Envelope.err(e, runCatching { ctxNow() }.getOrElse { JSONObject() }, auditId), e.code.name, e.channel)
        } catch (e: Exception) {
            Gateway.retryGuard.recordFailure(name, fingerprint)
            val ge = GatewayError(ErrorCode.E_INTERNAL, "${e.javaClass.simpleName}: ${e.message}")
            finish(Envelope.err(ge, runCatching { ctxNow() }.getOrElse { JSONObject() }, auditId), "E_INTERNAL", "")
        }
    }

    private fun channelOf(name: String): String = when {
        name.startsWith("ui_") || name in setOf("type_text", "press_key", "wait_for") -> "a11y"
        name.startsWith("system_") || name in setOf("device_info", "clipboard", "media_query", "foreground_app", "keyboard_state") -> "api"
        name in setOf("open_uri", "intent_send", "share_text", "share_file", "app_launch") -> "intent"
        name == "screen_capture" -> "vision"
        name == "confirm" -> "overlay"
        else -> ""
    }
}
