package dev.magina.gateway.core

import java.security.SecureRandom

/**
 * 网关 token 的唯一取用点。
 *
 * 原实现是个**有副作用的 getter**：首次读取时生成并 `apply()` 落盘，且完全没有同步。
 * 两处并发首读（前台服务启动 `McpServer.start` 与主界面显示/复制 token）会各生成一个，
 * 后写覆盖先写——大脑侧配置里拿到的那个当场失效，表现是随机 401，极难归因。
 * `apply()` 又是异步落盘，进程在写盘前被杀还会丢。
 *
 * 这里把读→生成→落盘收成一个同步过程：**先落盘再返回**。返回了却没落盘，
 * 等于把一个重启后就不存在的 token 交出去。
 */
class TokenStore(
    private val read: () -> String?,
    private val write: (String) -> Unit,
    private val generate: () -> String = { newToken() },
) {
    private var cached: String? = null

    @Synchronized
    fun current(): String {
        cached?.let { return it }
        val stored = read()
        if (!stored.isNullOrBlank()) {
            cached = stored
            return stored
        }
        val fresh = generate()
        write(fresh)
        cached = fresh
        return fresh
    }

    companion object {
        /** 32 位十六进制（128 bit）。用 SecureRandom，不依赖 UUID 实现细节。 */
        fun newToken(): String {
            val bytes = ByteArray(16)
            SecureRandom().nextBytes(bytes)
            return bytes.joinToString("") { "%02x".format(it) }
        }
    }
}
