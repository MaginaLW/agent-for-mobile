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
