package dev.magina.gateway.core

import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TokenStoreTest {

    @Test
    fun `已有 token 直接复用，不重新生成也不写盘`() {
        val writes = AtomicInteger()
        val store = TokenStore(
            read = { "existing-token" },
            write = { writes.incrementAndGet() },
            generate = { "should-not-be-used" },
        )
        assertEquals("existing-token", store.current())
        assertEquals(0, writes.get())
    }

    @Test
    fun `首次生成必须先落盘再返回`() {
        var persisted: String? = null
        var returnedWhilePersisting: String? = null
        val store = TokenStore(
            read = { persisted },
            write = { persisted = it },
            generate = { "fresh-token" },
        )
        returnedWhilePersisting = store.current()
        assertEquals("fresh-token", returnedWhilePersisting)
        // 返回了却没落盘，等于交出一个重启后就不存在的 token。
        assertEquals("fresh-token", persisted)
    }

    /**
     * 这是这个类存在的理由：原实现是无同步的 getter，服务启动与主界面并发首读会各生成一个、
     * 后写覆盖先写，于是大脑侧配置里那个当场失效——表现是随机 401，极难归因。
     */
    @Test
    fun `并发首读只生成一次且所有调用拿到同一个 token`() {
        val generated = AtomicInteger()
        val writes = AtomicInteger()
        var persisted: String? = null
        val store = TokenStore(
            read = { persisted },
            write = { persisted = it; writes.incrementAndGet() },
            generate = { "token-${generated.incrementAndGet()}" },
        )

        val threads = 16
        val start = CountDownLatch(1)
        val done = CountDownLatch(threads)
        val results = java.util.Collections.synchronizedList(mutableListOf<String>())
        repeat(threads) {
            Thread {
                start.await()
                results.add(store.current())
                done.countDown()
            }.start()
        }
        start.countDown()
        done.await()

        assertEquals(threads, results.size)
        assertEquals(1, results.toSet().size)
        assertEquals(1, generated.get())
        assertEquals(1, writes.get())
    }

    @Test
    fun `默认生成的是 32 位十六进制且每次不同`() {
        val a = TokenStore.newToken()
        val b = TokenStore.newToken()
        assertTrue(a.matches(Regex("^[0-9a-f]{32}$")))
        assertTrue(a != b)
    }
}
