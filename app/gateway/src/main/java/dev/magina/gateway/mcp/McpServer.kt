package dev.magina.gateway.mcp

import io.ktor.http.HttpStatusCode
import io.ktor.server.application.ApplicationCall
import io.ktor.server.application.call
import io.ktor.server.cio.CIO
import io.ktor.server.engine.ApplicationEngine
import io.ktor.server.engine.embeddedServer
import io.ktor.server.request.header
import io.ktor.server.request.receiveText
import io.ktor.http.ContentType
import io.ktor.server.response.respondText
import io.ktor.server.response.respondTextWriter
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import io.ktor.server.routing.routing
import dev.magina.gateway.core.AcceptNegotiation
import dev.magina.gateway.core.BearerAuthGuard
import dev.magina.gateway.core.CallHeartbeat
import dev.magina.gateway.core.NoHeartbeat
import dev.magina.gateway.core.TransportHeartbeatPolicy
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONArray
import org.json.JSONObject
import java.io.Writer
import java.util.concurrent.atomic.AtomicInteger

/**
 * MCP Streamable HTTP server（主设计契约：MCP over HTTP + token）。
 * - 只绑 127.0.0.1：M1 经 `adb forward tcp:8848 tcp:8848` 接 PC 大脑；M2 本机 localhost 直连。
 * - `tools/call` 走 **SSE 流式**并在长阻塞期间发心跳（见 [handleToolCall]）；其余方法仍是单响应。
 *   会话无状态。
 * - 大脑侧配置见 configs/gateway-mcp.json。
 */
object McpServer {

    private const val PROTOCOL_FALLBACK = "2025-03-26"
    private var engine: ApplicationEngine? = null
    val running: Boolean get() = engine != null

    fun start(port: Int, token: String) {
        if (engine != null) return
        val guard = BearerAuthGuard(token)
        engine = embeddedServer(CIO, port = port, host = "127.0.0.1") {
            routing {
                get("/health") { call.respondText("ok") }
                get("/mcp") { call.respondText("", status = HttpStatusCode.MethodNotAllowed) }
                post("/mcp") { handle(call, guard) }
            }
        }.start(wait = false)
    }

    fun stop() {
        engine?.stop(500, 1500)
        engine = null
    }

    private suspend fun handle(call: ApplicationCall, guard: BearerAuthGuard) {
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

        // 通知类消息无 id，按规范回 202
        if (id == null || id == JSONObject.NULL) {
            call.respondText("", status = HttpStatusCode.Accepted)
            return
        }

        if (method == "tools/call") {
            handleToolCall(call, id, params)
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
            // tools/call 走 SSE 流式，见 handleToolCall；这里不该再走到它。
            "tools/call" -> rpcError(id, -32603, "tools/call 必须走流式分支")
            else -> rpcError(id, -32601, "method not found: $method")
        }
        call.respondText(response.toString(), io.ktor.http.ContentType.Application.Json)
    }

    /**
     * `tools/call` 的流式分支。**改成 SSE 不是为了流式本身，是为了能在长阻塞期间发心跳**
     * （[TransportHeartbeatPolicy]）：客户端对 HTTP MCP 有 60s 首字节计时器与 300s 空闲
     * 看门狗两道，而语义意图那条链要求一次 `press_key` 最长开到 400s 量级。
     *
     * 2026-08-08 对照实测：**同样走 SSE、同样先把首字节发出去，期间不发通知照样在 300s
     * 处被砍；每 60s 发一条，330s 顺利返回。** 所以两件事缺一不可——SSE 只是通道，
     * 真正顶住空闲看门狗的是心跳。（第一道 60s 由客户端配置里的 `timeout` 抬高，不在这里。）
     *
     * **trace 形态没有变**：同轮实测，进度通知在 `--output-format stream-json` 里
     * **一条记录都不产生**，`tool_use → tool_result` 那一对与改造前逐字相同。
     */
    private suspend fun handleToolCall(call: ApplicationCall, id: Any, params: JSONObject) {
        val name = params.optString("name")
        val args = params.optJSONObject("arguments") ?: JSONObject()
        // **按 Accept 协商，不是无条件流式**：仓库里还有两个直连 HTTP 的只读探针把响应体
        // 当整包 JSON 解析，`data: {...}` 的第一个字符就能把它们打死（2026-08-08 实锤，
        // Allow 腿在第 1 腿判死，而消息其实已经发出去了）。见 [AcceptNegotiation]。
        if (!AcceptNegotiation.wantsEventStream(call.request.header("Accept"))) {
            val result = withContext(Dispatchers.IO) { ToolRegistry.call(name, args, NoHeartbeat) }
            call.respondText(
                toolCallResult(id, result).toString(),
                io.ktor.http.ContentType.Application.Json,
            )
            return
        }
        // 协议要求进度通知必须挂在客户端给的 token 上；没给就一拍都不发（实测 claude 会给）。
        val token = params.optJSONObject("_meta")?.opt("progressToken")
            ?.takeIf { it != JSONObject.NULL }
        val beats = AtomicInteger(0)
        val heartbeat = object : CallHeartbeat {
            override fun beats(): Int = beats.get()
            override fun tokenPresent(): Boolean = token != null
        }
        call.respondTextWriter(ContentType.Text.EventStream) {
            // 首字节：响应头一发出去，60s 那道计时器就不再是问题（但空闲看门狗还在）。
            flush()
            val work = CoroutineScope(Dispatchers.IO).async { ToolRegistry.call(name, args, heartbeat) }
            while (true) {
                val done = withTimeoutOrNull(TransportHeartbeatPolicy.HEARTBEAT_INTERVAL_MS) { work.await() }
                if (done != null) {
                    writeSse(this, toolCallResult(id, done))
                    break
                }
                if (token == null) continue
                // **只带数字**：progress 是已发拍数，不填 MCP 那个可选的 message 字段。
                // 心跳实时到达大脑，写任何带指引意味的话都等于教它重试（见 CallHeartbeat 文档）。
                writeSse(
                    this,
                    JSONObject().put("jsonrpc", "2.0").put("method", "notifications/progress").put(
                        "params",
                        JSONObject()
                            .put("progressToken", token)
                            .put("progress", beats.incrementAndGet()),
                    ),
                )
            }
        }
    }

    private suspend fun writeSse(writer: Writer, payload: JSONObject) {
        writer.write("data: $payload\n\n")
        writer.flush()
    }

    private fun toolCallResult(id: Any, result: ToolResult): JSONObject {
        val content = JSONArray().put(
            JSONObject().put("type", "text").put("text", result.envelope.toString()),
        )
        result.imageBase64?.let {
            content.put(
                JSONObject().put("type", "image").put("data", it).put("mimeType", result.imageMime),
            )
        }
        // 信封自带 ok/error 语义，isError 恒 false 让大脑读结构化错误而非裸报错文本
        return rpcResult(id, JSONObject().put("content", content).put("isError", false))
    }

    private fun rpcResult(id: Any, result: JSONObject): JSONObject =
        JSONObject().put("jsonrpc", "2.0").put("id", id).put("result", result)

    private fun rpcError(id: Any, code: Int, message: String): JSONObject =
        JSONObject().put("jsonrpc", "2.0").put("id", id)
            .put("error", JSONObject().put("code", code).put("message", message))
}
