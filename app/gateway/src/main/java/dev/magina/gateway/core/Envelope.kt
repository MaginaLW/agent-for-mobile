package dev.magina.gateway.core

import org.json.JSONObject

/** 封闭错误码集（spec §4）。大脑可据此写死策略。 */
enum class ErrorCode {
    E_PERM_MISSING, E_CHANNEL_DOWN, E_UNSUPPORTED_KEY, E_NOT_FOUND, E_AMBIGUOUS,
    E_STALE_REF, E_TIMEOUT, E_VERIFY_FAIL, E_BLOCKED, E_CONFIRM_REQUIRED,
    E_CONFIRM_TIMEOUT, E_RETRY_EXHAUSTED, E_LOW_CONFIDENCE, E_RATE_LIMITED,
    E_INVALID_ARG, E_INTERNAL
}

/** 工具实现内 throw 即可，路由层统一包装成错误信封。 */
class GatewayError(
    val code: ErrorCode,
    message: String,
    val channel: String = "",
    val retryable: Boolean = false,
    val fallback: String = "",
    val extra: JSONObject? = null,
) : Exception(message)

/** 统一响应信封：{ok, data|error, ctx, audit_id}。ctx 由 a11y 服务提供（不在线时给降级 ctx）。 */
object Envelope {

    fun ok(data: JSONObject, ctx: JSONObject, auditId: String): JSONObject =
        JSONObject()
            .put("ok", true)
            .put("data", data)
            .put("ctx", ctx)
            .put("audit_id", auditId)

    fun err(e: GatewayError, ctx: JSONObject, auditId: String): JSONObject {
        val err = JSONObject()
            .put("code", e.code.name)
            .put("message", e.message ?: "")
            .put("channel", e.channel)
            .put("retryable", e.retryable)
            .put("fallback", e.fallback)
        e.extra?.let { err.put("extra", it) }
        return JSONObject()
            .put("ok", false)
            .put("error", err)
            .put("ctx", ctx)
            .put("audit_id", auditId)
    }
}
