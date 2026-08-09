package dev.magina.gateway.ime

import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.GatewayError
import dev.magina.gateway.tools.requireCurrentEnterSession
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.lang.reflect.Proxy

class ImeBridgeSessionEnterTest {
    private var editorActions = 0
    private var keyEvents = 0

    @After
    fun cleanup() = ImeBridge.finishSession()

    @Test
    fun `final enter rejects a package switch after evidence validation`() {
        val connection = fakeConnection()
        ImeBridge.startSession("session-a", "com.tencent.mm", sendContract()) { connection }
        val validated = ImeBridge.session()!!

        // 模拟证据校验完成后、真正取 InputConnection 之前，系统把输入会话切到另一个 App。
        ImeBridge.startSession("session-a", "com.example.other", sendContract()) { connection }

        assertFalse(ImeBridge.enterIfCurrentSession("com.tencent.mm", validated.id) { true })
        assertEquals(0, editorActions)
    }

    @Test
    fun `final enter rejects a session id switch after evidence validation`() {
        val connection = fakeConnection()
        ImeBridge.startSession("session-a", "com.tencent.mm", sendContract()) { connection }

        ImeBridge.startSession("session-b", "com.tencent.mm", sendContract()) { connection }

        assertFalse(ImeBridge.enterIfCurrentSession("com.tencent.mm", "session-a") { true })
        assertEquals(0, editorActions)
    }

    @Test
    fun `final enter uses the connection once when package and session are still current`() {
        val connection = fakeConnection()
        ImeBridge.startSession("session-a", "com.tencent.mm", sendContract()) { connection }

        assertTrue(ImeBridge.enterIfCurrentSession("com.tencent.mm", "session-a") { true })
        assertEquals(1, editorActions)
    }

    @Test
    fun `session captures one connection generation instead of following a drifting supplier`() {
        var oldConnectionActions = 0
        var replacementConnectionActions = 0
        var supplierCalls = 0
        val oldConnection = fakeConnection { oldConnectionActions++ }
        val replacementConnection = fakeConnection { replacementConnectionActions++ }
        var suppliedConnection = oldConnection

        ImeBridge.startSession("session-a", "com.tencent.mm", sendContract()) {
            supplierCalls++
            suppliedConnection
        }
        // 元数据仍是 session-a，但动态 supplier 已漂到另一个世代的连接。
        suppliedConnection = replacementConnection

        assertTrue(ImeBridge.enterIfCurrentSession("com.tencent.mm", "session-a") { true })
        assertEquals("连接只能在 session 建立时捕获一次", 1, supplierCalls)
        assertEquals("投递必须落到与元数据同世代的旧连接", 1, oldConnectionActions)
        assertEquals("不得在校验后重新取另一个世代的连接", 0, replacementConnectionActions)
    }

    @Test
    fun `failed connection capture clears the previous session before propagating`() {
        val oldConnection = fakeConnection()
        ImeBridge.startSession("session-old", "com.tencent.mm", sendContract()) { oldConnection }

        try {
            ImeBridge.startSession("session-new", "com.example.other", sendContract()) {
                throw IllegalStateException("connection generation changed")
            }
            fail("连接快照失败必须向调用方暴露")
        } catch (_: IllegalStateException) {
            // expected
        }

        assertNull("失败后旧会话不得继续冒充 current", ImeBridge.session())
        assertFalse(ImeBridge.active)
        assertFalse(ImeBridge.enterIfCurrentSession("com.tencent.mm", "session-old") { true })
        assertEquals("失败后不得向旧连接投递", 0, editorActions)
    }

    @Test
    fun `a11y enter false never falls through to an IME delivery`() {
        val connection = fakeConnection()
        var a11yActions = 0
        ImeBridge.startSession("session-a", "com.tencent.mm", sendContract()) { connection }

        val entered = ImeBridge.enterIfCurrentSession(
            expectedPackage = "com.tencent.mm",
            expectedSessionId = "session-a",
            fastPrecondition = { true },
            a11yAction = {
                a11yActions++
                false
            },
        )

        assertFalse(entered)
        assertEquals(1, a11yActions)
        assertEquals("a11y 返回 false 后也不得换 IME 再投一次", 0, editorActions)
        assertEquals("a11y_ime_enter", ImeBridge.lastEnterChannel)
    }

    @Test
    fun `a11y delivery exception is a single channel non retryable failure`() {
        val connection = fakeConnection()
        var a11yActions = 0
        ImeBridge.startSession("session-a", "com.tencent.mm", sendContract()) { connection }

        val entered = ImeBridge.enterIfCurrentSession(
            expectedPackage = "com.tencent.mm",
            expectedSessionId = "session-a",
            fastPrecondition = { true },
            a11yAction = {
                // 抛出前可能已经部分投递；因此绝不能把异常当成“没送”后换 IME 再来一次。
                a11yActions++
                throw IllegalStateException("node action result unavailable")
            },
        )

        assertFalse(entered)
        assertEquals(1, a11yActions)
        assertEquals("异常后不得换 IME 第二次投递", 0, editorActions)
        assertFailedEnterIsReadOnlyAndNonRetryable(entered)
    }

    @Test
    fun `IME delivery exception is a single channel non retryable failure`() {
        val connection = fakeConnection {
            // App 可能已经消费动作，只是返回路径抛错；这是最需要禁止 fallback 的情形。
            editorActions++
            throw IllegalStateException("remote result unavailable")
        }
        ImeBridge.startSession("session-a", "com.tencent.mm", sendContract()) { connection }

        val entered = ImeBridge.enterIfCurrentSession("com.tencent.mm", "session-a") { true }

        assertFalse(entered)
        assertEquals(1, editorActions)
        assertEquals("editor action 抛错后不得退到 key event", 0, keyEvents)
        assertFailedEnterIsReadOnlyAndNonRetryable(entered)
    }

    @Test
    fun `a11y enter validates the switched session before touching the node and maps stale`() {
        val connection = fakeConnection()
        var a11yActions = 0
        ImeBridge.startSession("session-a", "com.tencent.mm", sendContract()) { connection }
        ImeBridge.startSession("session-b", "com.tencent.mm", sendContract()) { connection }

        val entered = ImeBridge.enterIfCurrentSession(
            expectedPackage = "com.tencent.mm",
            expectedSessionId = "session-a",
            fastPrecondition = { true },
            a11yAction = {
                a11yActions++
                true
            },
        )

        assertEquals(0, a11yActions)
        try {
            requireCurrentEnterSession(entered, ImeBridge.lastEnterChannel)
            fail("a11y 可用也必须把最终会话切换映射成 E_STALE_REF")
        } catch (error: GatewayError) {
            assertEquals(ErrorCode.E_STALE_REF, error.code)
        }
    }

    @Test
    fun `final fresh precondition rejects before either enter channel`() {
        val connection = fakeConnection()
        var a11yActions = 0
        var fastChecks = 0
        ImeBridge.startSession("session-a", "com.tencent.mm", sendContract()) { connection }

        val a11yEntered = ImeBridge.enterIfCurrentSession(
            expectedPackage = "com.tencent.mm",
            expectedSessionId = "session-a",
            fastPrecondition = { fastChecks += 1; false },
            a11yAction = { a11yActions += 1; true },
        )
        assertFalse(a11yEntered)
        assertEquals("fresh_surface_stale", ImeBridge.lastEnterChannel)
        assertEquals(0, a11yActions)
        assertEquals(0, editorActions)

        val imeEntered = ImeBridge.enterIfCurrentSession(
            expectedPackage = "com.tencent.mm",
            expectedSessionId = "session-a",
            fastPrecondition = {
                fastChecks += 1
                throw IllegalStateException("surface state unavailable")
            },
        )
        assertFalse(imeEntered)
        assertEquals("fresh_surface_stale", ImeBridge.lastEnterChannel)
        assertEquals(0, a11yActions)
        assertEquals("fresh check failure must not touch InputConnection", 0, editorActions)
        assertEquals(2, fastChecks)

        try {
            requireCurrentEnterSession(imeEntered, ImeBridge.lastEnterChannel)
            fail("fresh surface drift must map to terminal stale")
        } catch (error: GatewayError) {
            assertEquals(ErrorCode.E_STALE_REF, error.code)
            assertFalse(error.retryable)
        }
    }

    @Test
    fun `any failed enter delivery is non retryable and forbids switching channels`() {
        assertFailedEnterIsReadOnlyAndNonRetryable(
            entered = false,
            enterChannel = "a11y_ime_enter",
        )
    }

    private fun assertFailedEnterIsReadOnlyAndNonRetryable(
        entered: Boolean,
        enterChannel: String? = ImeBridge.lastEnterChannel,
    ) {
        try {
            requireCurrentEnterSession(entered = entered, enterChannel = enterChannel)
            fail("Enter 投递失败不得落入通用 retryable 错误")
        } catch (error: GatewayError) {
            assertEquals(ErrorCode.E_VERIFY_FAIL, error.code)
            assertFalse(error.retryable)
            assertTrue(error.fallback.contains("只读复核"))
            assertTrue(error.fallback.contains("不得重试"))
        }
    }

    private fun sendContract() = ImeEditorContract(
        inputType = 1,
        imeOptions = EditorInfo.IME_ACTION_SEND,
        actionId = 0,
        actionLabel = null,
    )

    private fun fakeConnection(
        onEditorAction: () -> Unit = { editorActions += 1 },
    ): InputConnection = Proxy.newProxyInstance(
        InputConnection::class.java.classLoader,
        arrayOf(InputConnection::class.java),
    ) { _, method, _ ->
        when (method.name) {
            "performEditorAction" -> {
                onEditorAction()
                true
            }
            "sendKeyEvent" -> {
                keyEvents++
                true
            }
            else -> when (method.returnType) {
                java.lang.Boolean.TYPE -> false
                java.lang.Integer.TYPE -> 0
                else -> null
            }
        }
    } as InputConnection
}
