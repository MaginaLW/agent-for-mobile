package dev.magina.gateway.core

/**
 * 长阻塞工具调用期间往 MCP 传输层发的**心跳**（`notifications/progress`）。
 *
 * 为什么需要它（2026-08-08 实测，见 [knowledge/brain/harness.md] 那一节）：
 * 客户端对 HTTP/SSE 的 MCP 服务器有**两道天花板**——60s 的「首字节」计时器，
 * 和 300s 的「空闲看门狗」（一次调用期间既无响应也无进度通知就中止）。
 * 而语义意图那条链要求一次 `press_key` 最长开到「决定 90s + 等前台 300s + 开销」≈400s。
 *
 * 对照实测钉死的结论：**同样走 SSE、同样先把首字节发出去，不发通知照样在 300s 处被砍；
 * 每 60s 发一条，330s 顺利返回。** 起作用的是通知，不是流式本身。
 *
 * **心跳只带数字，不带任何内容**，两条理由都不是洁癖：
 *
 * 1. 已批准内容（`ApprovalIntent.contentNormalized`）是**进程内存、不落盘、不进日志、
 *    不进信封、不进 trace**，连 `toString` 都专门脱敏过。**心跳是发给大脑的**，
 *    带上内容等于把前面那一整套约束一次作废。
 * 2. 心跳会在调用期间**实时**到达执行器。提示词里我们特意一个字都不提「切走/等待/停留」
 *    并用离线用例钉住——理由是**告诉执行器正在发生什么，等于给它"再试一次也许就好了"的
 *    理由**，而站规要求安全失败即终态。心跳写成「正在等前台恢复，稍后回来」这类带指引
 *    意味的话，等于把堵住的那个洞从另一头挖开。所以 MCP progress 的可选 `message` 字段
 *    **一律不填**。
 */
interface CallHeartbeat {
    /** 到目前为止发出去了几拍。只用于取证，不参与任何放行判定。 */
    fun beats(): Int

    /** 客户端有没有给 `params._meta.progressToken`。没给就发不了进度通知（协议要求）。 */
    fun tokenPresent(): Boolean

    /** 进审计 note 的取证串：**没有它，"心跳到底有没有发"在台账上完全看不见**。 */
    fun describe(): String = "beats=${beats()},token=${if (tokenPresent()) "yes" else "no"}"
}

/** 一拍都不发的实现；非流式调用方与离线用例用它。 */
object NoHeartbeat : CallHeartbeat {
    override fun beats(): Int = 0
    override fun tokenPresent(): Boolean = false
}

/**
 * `tools/call` 到底回**流式 SSE** 还是**整包 JSON**：按客户端的 `Accept` 协商。
 *
 * **这条判据是 2026-08-08 第二跑烧出来的**：改 SSE 时我让 `tools/call` **无条件**回
 * `text/event-stream`，而仓库里还有两个**直连 HTTP 的只读探针**
 * （`p0-probe-region-precheck.ps1` / `p0-foreground-bootstrap-check.ps1`）把响应体当整包
 * JSON 解析——`data: {...}` 的第一个字符 `d` 当场把解析器打死，连锁成"marker 不在合法
 * 消息区"，Allow 腿在第 1 腿判死，**而消息其实已经发出去了**。
 *
 * **改一个共享输出格式时，必须先穷举它的消费者。** 这是两天内同一形状的第三次
 * （闸门与产出各写一份 · fixture 少拷文件 · 传输帧与直连消费者），三次都是
 * **两个都对、接起来不对**。
 *
 * **按 `Accept` 协商之所以成立，是量出来的不是推出来的**：claude 2.1.206 的 MCP 客户端
 * 在 `tools/call` 上实测发的是 `application/json, text/event-stream`（四次独立观测）。
 * 若它哪天不发这个头，协商会把它切回非流式、心跳随之消失、300s 空闲窗当场回来——
 * **而那次的失败形态与批次 4 首跑一模一样（约 90s 断开、无错误码），最难认**。
 * 所以真实客户端那条 Accept 被写成用例钉住：它变了，用例先红，而不是真机先红。
 */
object AcceptNegotiation {

    /** 实测：claude 2.1.206 的 MCP 客户端在 `tools/call` 上发的就是这一串。 */
    const val MEASURED_CLIENT_ACCEPT = "application/json, text/event-stream"

    /** 直连只读探针显式声明"我要整包 JSON"，不靠"它恰好没发 Accept"这种巧合。 */
    const val PLAIN_JSON_ACCEPT = "application/json"

    private const val EVENT_STREAM = "text/event-stream"

    /**
     * 缺省（没有 `Accept` 头）**回非流式**。fail-safe 方向选这一边的理由：
     * 猜错成流式会打死一个只会解 JSON 的老实客户端（今天这次），
     * 猜错成非流式只是让长调用退回没有心跳的老行为——后者仍会失败，但不会把别人的解析器打死。
     */
    fun wantsEventStream(accept: String?): Boolean =
        accept != null && accept.split(',').any { it.substringBefore(';').trim().equals(EVENT_STREAM, true) }
}

/**
 * 心跳间隔与客户端空闲窗的关系。
 *
 * **两个数写在一起并用断言绑住，而不是各放一处**：它们一旦被人分别改动，失效方式是
 * **静默**的——心跳变稀或空闲窗变紧，都只会表现为"某次长调用莫名其妙超时"，
 * 而那与"功能坏了"长得一模一样。
 */
object TransportHeartbeatPolicy {

    /**
     * 客户端 HTTP/SSE 空闲看门狗的窗口。**这是别人家的默认值，我们只能迁就**
     * （claude 2.1.206 实测：`CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT` 要 ≥2.1.210 才存在，
     * per-server `timeout` 也抬不动它）。
     */
    const val CLIENT_IDLE_WINDOW_MS = 300_000L

    /** 心跳间隔。取 60s = 空闲窗的 1/5，留 5 倍余量。 */
    const val HEARTBEAT_INTERVAL_MS = 60_000L

    /**
     * 余量下限。**不写"小于空闲窗就行"**：那样只留一拍余量，一次 GC 卡顿或一次
     * 调度延迟就会踩线，而失败形态与"功能坏了"分不开。
     */
    const val MIN_BEATS_WITHIN_IDLE_WINDOW = 4

    init {
        require(HEARTBEAT_INTERVAL_MS > 0) { "心跳间隔必须大于 0" }
        require(HEARTBEAT_INTERVAL_MS * MIN_BEATS_WITHIN_IDLE_WINDOW <= CLIENT_IDLE_WINDOW_MS) {
            "心跳间隔 ${HEARTBEAT_INTERVAL_MS}ms 在客户端空闲窗 ${CLIENT_IDLE_WINDOW_MS}ms 内" +
                "凑不满 $MIN_BEATS_WITHIN_IDLE_WINDOW 拍：余量不够，一次调度延迟就会踩线，" +
                "而超时与「功能坏了」在现场分不开"
        }
    }

    /** 空闲窗内能发出的心跳拍数，供用例与诊断读。 */
    val beatsPerIdleWindow: Int get() = (CLIENT_IDLE_WINDOW_MS / HEARTBEAT_INTERVAL_MS).toInt()
}
