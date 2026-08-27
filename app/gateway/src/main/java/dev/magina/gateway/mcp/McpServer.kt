package dev.magina.gateway.mcp

import io.ktor.http.ContentType
import io.ktor.http.HttpStatusCode
import io.ktor.server.application.ApplicationCall
import io.ktor.server.application.call
import io.ktor.server.cio.CIO
import io.ktor.server.engine.ApplicationEngine
import io.ktor.server.engine.embeddedServer
import io.ktor.server.request.header
import io.ktor.server.request.receiveText
import io.ktor.server.response.respondText
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import io.ktor.server.routing.routing
import dev.magina.gateway.core.BearerAuthGuard
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
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

    private var engine: ApplicationEngine? = null
    val running: Boolean get() = engine != null

    fun start(port: Int, token: String) {
        if (engine != null) return
        val guard = BearerAuthGuard(token)
        engine = embeddedServer(CIO, port = port, host = "127.0.0.1") {
            routing {
                get("/health") {
                    if (acceptOriginOrRespond(call)) call.respondText("ok")
                }
                get("/mcp") {
                    if (acceptOriginOrRespond(call)) {
                        call.respondText("", status = HttpStatusCode.MethodNotAllowed)
                    }
                }
                post("/mcp") { handle(call, guard) }
            }
        }.start(wait = false)
    }

    fun stop() {
        engine?.stop(500, 1500)
        engine = null
    }

    private suspend fun handle(call: ApplicationCall, guard: BearerAuthGuard) {
        if (!acceptOriginOrRespond(call)) return
        val verdict = guard.check(call.request.header("Authorization"))
        if (!verdict.allowed) {
            // 失败退避：拖慢猜测，不锁死端口（锁死会让同机乱打的进程把我们自己也挡在外面）。
            if (verdict.delayMs > 0) delay(verdict.delayMs)
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

        if (!McpTransportPolicy.acceptsProtocolVersion(
                method = method,
                headerVersion = call.request.header("MCP-Protocol-Version"),
            )
        ) {
            call.respondText(
                rpcError(
                    id ?: JSONObject.NULL,
                    -32600,
                    "unsupported MCP-Protocol-Version; supported=${McpTransportPolicy.SUPPORTED_PROTOCOL_VERSION}",
                ).toString(),
                contentType = ContentType.Application.Json,
                status = HttpStatusCode.BadRequest,
            )
            return
        }

        // 通知类消息无 id，按规范回 202
        if (id == null || id == JSONObject.NULL) {
            call.respondText("", status = HttpStatusCode.Accepted)
            return
        }

        val response: JSONObject = when (method) {
            "initialize" -> rpcResult(
                id,
                JSONObject()
                    .put(
                        "protocolVersion",
                        McpTransportPolicy.negotiateProtocolVersion(params.opt("protocolVersion") as? String),
                    )
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
                rpcResult(
                    id,
                    JSONObject()
                        .put("content", content)
                        .put("isError", McpTransportPolicy.toolResultIsError(result.envelope)),
                )
            }
            else -> rpcError(id, -32601, "method not found: $method")
        }
        call.respondText(response.toString(), ContentType.Application.Json)
    }

    /** Origin 必须先于鉴权和正文处理；不可信网页不能借 localhost 与 token 端点交互。 */
    private suspend fun acceptOriginOrRespond(call: ApplicationCall): Boolean {
        if (McpTransportPolicy.acceptsOrigin(call.request.header("Origin"))) return true
        call.respondText(
            """{"error":"forbidden_origin"}""",
            contentType = ContentType.Application.Json,
            status = HttpStatusCode.Forbidden,
        )
        return false
    }

    private fun rpcResult(id: Any, result: JSONObject): JSONObject =
        JSONObject().put("jsonrpc", "2.0").put("id", id).put("result", result)

    private fun rpcError(id: Any, code: Int, message: String): JSONObject =
        JSONObject().put("jsonrpc", "2.0").put("id", id)
            .put("error", JSONObject().put("code", code).put("message", message))
}
