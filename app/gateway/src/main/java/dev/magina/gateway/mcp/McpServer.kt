package dev.magina.gateway.mcp

import io.ktor.http.HttpStatusCode
import io.ktor.server.application.ApplicationCall
import io.ktor.server.cio.CIO
import io.ktor.server.engine.ApplicationEngine
import io.ktor.server.engine.embeddedServer
import io.ktor.server.request.header
import io.ktor.server.request.receiveText
import io.ktor.server.response.respondText
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import io.ktor.server.routing.routing
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

/**
 * MCP Streamable HTTP server（主设计契约：MCP over HTTP + token）。
 * - 只绑 127.0.0.1：M1 经 `adb forward tcp:8848 tcp:8848` 接 PC 大脑；M2 本机 localhost 直连。
 * - 无 SSE 流（单响应模式，Streamable HTTP 规范允许）；会话无状态。
 * - 大脑侧配置见 configs/gateway-mcp.json。
 */
object McpServer {

    private const val PROTOCOL_FALLBACK = "2025-03-26"
    private var engine: ApplicationEngine? = null
    val running: Boolean get() = engine != null

    fun start(port: Int, token: String) {
        if (engine != null) return
        engine = embeddedServer(CIO, port = port, host = "127.0.0.1") {
            routing {
                get("/health") { call.respondText("ok") }
                get("/mcp") { call.respondText("", status = HttpStatusCode.MethodNotAllowed) }
                post("/mcp") { handle(call, token) }
            }
        }.start(wait = false)
    }

    fun stop() {
        engine?.stop(500, 1500)
        engine = null
    }

    private suspend fun handle(call: ApplicationCall, token: String) {
        val auth = call.request.header("Authorization") ?: ""
        if (auth != "Bearer $token") {
            call.respondText("""{"error":"unauthorized"}""", status = HttpStatusCode.Unauthorized)
            return
        }
        val req = try {
            JSONObject(call.receiveText())
        } catch (e: Exception) {
            call.respondText(rpcError(JSONObject.NULL, -32700, "parse error").toString())
            return
        }
        val method = req.optString("method")
        val id = req.opt("id")
        val params = req.optJSONObject("params") ?: JSONObject()

        // 通知类消息无 id，按规范回 202
        if (id == null || id == JSONObject.NULL) {
            call.respondText("", status = HttpStatusCode.Accepted)
            return
        }

        val response: JSONObject = when (method) {
            "initialize" -> rpcResult(
                id,
                JSONObject()
                    .put("protocolVersion", params.optString("protocolVersion", PROTOCOL_FALLBACK))
                    .put("capabilities", JSONObject().put("tools", JSONObject()))
                    .put(
                        "serverInfo",
                        JSONObject().put("name", "mobile-agent-gateway").put("version", "0.1.0-m1a"),
                    ),
            )
            "ping" -> rpcResult(id, JSONObject())
            "tools/list" -> rpcResult(id, JSONObject().put("tools", ToolRegistry.listToolsJson()))
            "resources/list" -> rpcResult(id, JSONObject().put("resources", JSONArray()))
            "prompts/list" -> rpcResult(id, JSONObject().put("prompts", JSONArray()))
            "tools/call" -> {
                val name = params.optString("name")
                val args = params.optJSONObject("arguments") ?: JSONObject()
                // 工具实现含阻塞等待（wait_for/确认卡片），放 IO 线程池
                val result = withContext(Dispatchers.IO) { ToolRegistry.call(name, args) }
                val content = JSONArray().put(
                    JSONObject().put("type", "text").put("text", result.envelope.toString()),
                )
                result.imageBase64?.let {
                    content.put(
                        JSONObject().put("type", "image").put("data", it).put("mimeType", result.imageMime),
                    )
                }
                // 信封自带 ok/error 语义，isError 恒 false 让大脑读结构化错误而非裸报错文本
                rpcResult(id, JSONObject().put("content", content).put("isError", false))
            }
            else -> rpcError(id, -32601, "method not found: $method")
        }
        call.respondText(response.toString(), io.ktor.http.ContentType.Application.Json)
    }

    private fun rpcResult(id: Any, result: JSONObject): JSONObject =
        JSONObject().put("jsonrpc", "2.0").put("id", id).put("result", result)

    private fun rpcError(id: Any, code: Int, message: String): JSONObject =
        JSONObject().put("jsonrpc", "2.0").put("id", id)
            .put("error", JSONObject().put("code", code).put("message", message))
}
