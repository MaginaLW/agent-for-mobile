package dev.magina.gateway.tools

import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.GatewayError
import org.json.JSONObject

/** release 构建不注册验收宏；任意名称都封闭失败。 */
internal object MacroRunnerFactory {
    fun run(@Suppress("UNUSED_PARAMETER") args: JSONObject): JSONObject = throw GatewayError(
        ErrorCode.E_CHANNEL_DOWN,
        "release 构建未启用调试验收宏",
        channel = "macro",
        retryable = false,
    )
}
