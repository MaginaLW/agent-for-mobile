package dev.magina.gateway.macro

import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.GatewayError
import org.json.JSONArray
import org.json.JSONObject
import java.net.URLEncoder
import java.nio.charset.StandardCharsets

internal data class MacroParamSpec(
    val name: String,
    val type: String,
    val required: Boolean,
    val minLength: Int,
    val maxLength: Int,
)

internal data class MacroAssertions(
    val packageEquals: String? = null,
    val notPackages: List<String> = emptyList(),
    val blockingOverlayFalse: Boolean = false,
    val noLoginWall: Boolean = false,
    val minMatches: Int? = null,
)

internal data class MacroStepSpec(
    val id: String,
    val tool: String,
    val argsTemplate: JSONObject,
    val optional: Boolean = false,
    val saveRef: String? = null,
    val skipIfRefMissing: Boolean = false,
    val handoffIfForegroundIs: String? = null,
    val handoffReason: String? = null,
    val captureAsFinalSnapshot: Boolean = false,
    val assertions: MacroAssertions? = null,
)

internal data class MacroSpec(
    val id: String,
    val version: Int,
    val app: String,
    val expectPackage: String,
    val description: String,
    val readonly: Boolean,
    val verified: String,
    val params: Map<String, MacroParamSpec>,
    val steps: List<MacroStepSpec>,
)

internal object MacroContract {
    val ALLOWED_STEP_TOOLS = setOf(
        "foreground_app",
        "system_get_state",
        "skillpack_lookup",
        "app_launch",
        "open_uri",
        "wait_for",
        "ui_snapshot",
        "ui_find",
        "ui_action",
        "type_text",
        "press_key",
    )

    val MUTATING_STEP_TOOLS = setOf(
        "app_launch",
        "open_uri",
        "ui_action",
        "type_text",
        "press_key",
    )

    val SAFETY_TERMINAL_ERROR_CODES = setOf(
        ErrorCode.E_BLOCKED.name,
        ErrorCode.E_CONFIRM_REQUIRED.name,
        ErrorCode.E_CONFIRM_TIMEOUT.name,
        ErrorCode.E_STALE_REF.name,
        ErrorCode.E_PERM_MISSING.name,
    )

    private val ID_REGEX = Regex("^[a-z0-9_]+$")
    private val DATE_REGEX = Regex("^\\d{4}-\\d{2}-\\d{2}$")
    private val TEMPLATE_REGEX = Regex("\\{\\{([^}]+)\\}\\}")
    private val PARAM_TOKEN_REGEX = Regex("^[a-zA-Z0-9_]+(\\|urlencode)?$")
    private val REF_TOKEN_REGEX = Regex("^ref:[a-zA-Z0-9_]+$")

    fun parseMacroSpec(
        json: JSONObject,
        isBlockedApp: (String?) -> Boolean,
    ): MacroSpec {
        val id = json.optString("id").trim()
        require(id.isNotEmpty() && ID_REGEX.matches(id)) { "宏 id 非法：$id" }
        val version = json.optInt("version", 0)
        require(version >= 1) { "宏 $id version 必须 >= 1" }
        val app = json.optString("app").trim()
        require(app.isNotEmpty()) { "宏 $id 缺少 app" }
        val expectPackage = json.optString("expect_package").trim()
        require(expectPackage.isNotEmpty()) { "宏 $id 缺少 expect_package" }
        require(!isBlockedApp(expectPackage)) { "宏 $id 的 expect_package 命中黑名单：$expectPackage" }
        val description = json.optString("description").trim()
        require(description.isNotEmpty()) { "宏 $id 缺少 description" }
        val readonly = json.optBoolean("readonly", false)
        val verified = json.optString("verified").trim()
        require(verified.isEmpty() || DATE_REGEX.matches(verified)) {
            "宏 $id verified 格式非法：$verified"
        }

        val paramsJson = json.optJSONObject("params") ?: JSONObject()
        val params = LinkedHashMap<String, MacroParamSpec>()
        for (paramName in paramsJson.keys()) {
            val pObj = paramsJson.getJSONObject(paramName)
            val pType = pObj.optString("type", "string")
            require(pType == "string") { "宏 $id 参数 $paramName 暂仅支持 string 类型" }
            val required = pObj.optBoolean("required", true)
            val minLen = pObj.optInt("min_length", 1)
            val maxLen = pObj.optInt("max_length", 128)
            require(minLen >= 0 && maxLen >= minLen) { "宏 $id 参数 $paramName 长度约束非法" }
            params[paramName] = MacroParamSpec(paramName, pType, required, minLen, maxLen)
        }

        val stepsArray = json.optJSONArray("steps")
        require(stepsArray != null && stepsArray.length() > 0) { "宏 $id steps 不能为空" }
        val steps = ArrayList<MacroStepSpec>(stepsArray.length())
        val stepIds = HashSet<String>()
        val declaredRefSlots = HashSet<String>()
        for (i in 0 until stepsArray.length()) {
            val s = stepsArray.getJSONObject(i)
            val stepId = s.optString("id").trim()
            require(stepId.isNotEmpty() && ID_REGEX.matches(stepId)) { "宏 $id 第 $i 步 id 非法：$stepId" }
            require(stepIds.add(stepId)) { "宏 $id 存在重复步骤 id：$stepId" }
            val tool = s.optString("tool").trim()
            require(tool in ALLOWED_STEP_TOOLS) { "宏 $id 步骤 $stepId 工具不在白名单：$tool" }
            val argsTemplate = s.optJSONObject("args") ?: JSONObject()
            validateTemplateObject(id, stepId, argsTemplate, params.keys)
            val referencedSlots = extractReferencedRefSlots(argsTemplate)
            for (slot in referencedSlots) {
                require(slot in declaredRefSlots) {
                    "宏 $id 步骤 $stepId 引用了未由前序步骤 save_ref 声明的槽位：$slot"
                }
            }
            val skipIfRefMissing = s.optBoolean("skip_if_ref_missing", false)
            if (skipIfRefMissing) {
                require(referencedSlots.isNotEmpty()) {
                    "宏 $id 步骤 $stepId 启用 skip_if_ref_missing 但 args 未引用任何 {{ref:...}} 槽位"
                }
            }

            val saveRef = s.optString("save_ref").trim().takeIf { it.isNotEmpty() }
            if (saveRef != null) {
                require(tool == "ui_find") { "宏 $id 步骤 $stepId 仅 ui_find 允许 save_ref" }
                declaredRefSlots.add(saveRef)
            }
            val handoffFg = s.optString("handoff_if_foreground_is").trim().takeIf { it.isNotEmpty() }
            val handoffReason = s.optString("handoff_reason").trim().takeIf { it.isNotEmpty() }
            val assertions = s.optJSONObject("assertions")?.let { a ->
                MacroAssertions(
                    packageEquals = a.optString("package_equals").trim().takeIf { it.isNotEmpty() },
                    notPackages = stringList(a.optJSONArray("not_packages")),
                    blockingOverlayFalse = a.optBoolean("blocking_overlay_false", false),
                    noLoginWall = a.optBoolean("no_login_wall", false),
                    minMatches = if (a.has("min_matches")) a.getInt("min_matches") else null,
                )
            }
            steps.add(
                MacroStepSpec(
                    id = stepId,
                    tool = tool,
                    argsTemplate = argsTemplate,
                    optional = s.optBoolean("optional", false),
                    saveRef = saveRef,
                    skipIfRefMissing = skipIfRefMissing,
                    handoffIfForegroundIs = handoffFg,
                    handoffReason = handoffReason,
                    captureAsFinalSnapshot = s.optBoolean("capture_as_final_snapshot", false),
                    assertions = assertions,
                ),
            )
        }

        return MacroSpec(
            id = id,
            version = version,
            app = app,
            expectPackage = expectPackage,
            description = description,
            readonly = readonly,
            verified = verified,
            params = params,
            steps = steps,
        )
    }

    private fun validateTemplateObject(
        macroId: String,
        stepId: String,
        obj: JSONObject,
        declaredParams: Set<String>,
    ) {
        for (k in obj.keys()) {
            validateTemplateValue(macroId, stepId, obj.opt(k), declaredParams)
        }
    }

    private fun validateTemplateValue(
        macroId: String,
        stepId: String,
        value: Any?,
        declaredParams: Set<String>,
    ) {
        when (value) {
            is JSONObject -> validateTemplateObject(macroId, stepId, value, declaredParams)
            is JSONArray -> {
                for (i in 0 until value.length()) {
                    validateTemplateValue(macroId, stepId, value.opt(i), declaredParams)
                }
            }
            is String -> {
                for (match in TEMPLATE_REGEX.findAll(value)) {
                    val token = match.groupValues[1].trim()
                    when {
                        REF_TOKEN_REGEX.matches(token) -> Unit
                        PARAM_TOKEN_REGEX.matches(token) -> {
                            val paramName = token.substringBefore('|')
                            require(paramName in declaredParams) {
                                "宏 $macroId 步骤 $stepId 引用了未声明参数：$paramName"
                            }
                        }
                        else -> throw IllegalArgumentException(
                            "宏 $macroId 步骤 $stepId 包含非法模板表达式：{{$token}}",
                        )
                    }
                }
            }
        }
    }

    fun extractReferencedRefSlots(template: JSONObject): Set<String> {
        val slots = LinkedHashSet<String>()
        collectRefSlots(template, slots)
        return slots
    }

    private fun collectRefSlots(value: Any?, out: MutableSet<String>) {
        when (value) {
            is JSONObject -> {
                for (k in value.keys()) {
                    collectRefSlots(value.opt(k), out)
                }
            }
            is JSONArray -> {
                for (i in 0 until value.length()) {
                    collectRefSlots(value.opt(i), out)
                }
            }
            is String -> {
                for (match in TEMPLATE_REGEX.findAll(value)) {
                    val token = match.groupValues[1].trim()
                    if (REF_TOKEN_REGEX.matches(token)) {
                        out.add(token.removePrefix("ref:"))
                    }
                }
            }
        }
    }

    fun renderArgs(
        template: JSONObject,
        params: Map<String, String>,
        savedRefs: Map<String, String>,
    ): JSONObject {
        val out = JSONObject()
        for (key in template.keys()) {
            out.put(key, renderValue(template.opt(key), params, savedRefs))
        }
        return out
    }

    private fun renderValue(
        value: Any?,
        params: Map<String, String>,
        savedRefs: Map<String, String>,
    ): Any? = when (value) {
        is JSONObject -> renderArgs(value, params, savedRefs)
        is JSONArray -> JSONArray().apply {
            for (i in 0 until value.length()) put(renderValue(value.opt(i), params, savedRefs))
        }
        is String -> renderTemplate(value, params, savedRefs)
        else -> value
    }

    fun renderTemplate(
        raw: String,
        params: Map<String, String>,
        savedRefs: Map<String, String>,
    ): String = TEMPLATE_REGEX.replace(raw) { match ->
        val token = match.groupValues[1].trim()
        when {
            token.startsWith("ref:") -> {
                val slot = token.removePrefix("ref:")
                savedRefs[slot] ?: throw GatewayError(
                    ErrorCode.E_STALE_REF,
                    "宏引用槽位 $slot 缺失或已在前序写操作后失效",
                    channel = "macro",
                    retryable = false,
                )
            }
            token.endsWith("|urlencode") -> {
                val paramName = token.removeSuffix("|urlencode")
                val v = params[paramName] ?: throw GatewayError(
                    ErrorCode.E_INVALID_ARG,
                    "缺少宏参数：$paramName",
                    channel = "macro",
                    retryable = false,
                )
                URLEncoder.encode(v, StandardCharsets.UTF_8.name()).replace("+", "%20")
            }
            else -> params[token] ?: throw GatewayError(
                ErrorCode.E_INVALID_ARG,
                "缺少宏参数：$token",
                channel = "macro",
                retryable = false,
            )
        }
    }

    private fun stringList(arr: JSONArray?): List<String> =
        if (arr == null) emptyList() else (0 until arr.length()).map { arr.getString(it) }
}
