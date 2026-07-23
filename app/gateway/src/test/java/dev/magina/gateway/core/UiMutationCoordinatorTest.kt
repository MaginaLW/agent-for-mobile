package dev.magina.gateway.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class UiMutationCoordinatorTest {
    @Test
    fun `all write calls and scrolling find serialize while snapshots remain readable`() {
        assertTrue(shouldSerializeUiCall(Level.W, "press_key", false))
        assertTrue(shouldSerializeUiCall(Level.W, "type_text", false))
        assertTrue(shouldSerializeUiCall(Level.D, "future_danger", false))
        assertTrue(shouldSerializeUiCall(Level.R, "ui_find", true))
        assertFalse(shouldSerializeUiCall(Level.R, "ui_snapshot", false))
        assertFalse(shouldSerializeUiCall(Level.R, "ui_find", false))
    }

    @Test
    fun `every write and scrolling find clear evidence except enter`() {
        val store = InputCommitEvidenceStore()

        fun seed() = store.record("待发送内容", "chat-input")
        listOf("click", "long_click", "dismiss", "scroll", "set_text").forEach { action ->
            seed()
            assertTrue(
                "ui_action($action) 必须清证据",
                invalidateInputEvidenceForMutation(
                    store,
                    level = Level.W,
                    toolName = "ui_action",
                    action = action,
                ),
            )
            assertEquals(null, store.current("chat-input"))
        }

        seed()
        assertTrue(
            invalidateInputEvidenceForMutation(store, Level.W, "type_text"),
        )
        assertEquals(null, store.current("chat-input"))

        seed()
        assertTrue(
            invalidateInputEvidenceForMutation(
                store,
                level = Level.R,
                toolName = "ui_find",
                scrollSearch = true,
            ),
        )
        assertEquals(null, store.current("chat-input"))

        val evidence = seed()
        assertFalse(
            invalidateInputEvidenceForMutation(
                store,
                level = Level.W,
                toolName = "press_key",
                key = "enter",
            ),
        )
        assertEquals(evidence, store.current("chat-input"))

        val readEvidence = seed()
        assertFalse(
            invalidateInputEvidenceForMutation(store, Level.R, "ui_snapshot"),
        )
        assertEquals(readEvidence, store.current("chat-input"))
    }

    @Test
    fun `prepared target survives only type text and enter mutation chain`() {
        val store = PreparedTargetEvidenceStore()

        fun seed() = store.record(
            label = "文件传输助手",
            packageName = "com.tencent.mm",
            focusedInputId = "7|id/chat_input|android.widget.EditText|com.tencent.mm|1,2,30,40",
            bounds = "[1,2][30,40]",
            imeSessionId = "ime|0123456789abcdef01234567",
        )

        val preservedByType = seed()
        assertFalse(invalidatePreparedTargetForMutation(store, Level.W, "type_text"))
        assertEquals(
            preservedByType,
            store.current(
                "com.tencent.mm",
                "7|id/chat_input|android.widget.EditText|com.tencent.mm|1,2,30,40",
                "[1,2][30,40]",
                "ime|0123456789abcdef01234567",
            ),
        )

        val preservedByEnter = seed()
        assertFalse(
            invalidatePreparedTargetForMutation(
                store,
                Level.W,
                "press_key",
                key = "enter",
            ),
        )
        assertEquals(
            preservedByEnter,
            store.current(
                "com.tencent.mm",
                "7|id/chat_input|android.widget.EditText|com.tencent.mm|1,2,30,40",
                "[1,2][30,40]",
                "ime|0123456789abcdef01234567",
            ),
        )

        listOf(
            Triple(Level.W, "macro_run", null),
            Triple(Level.W, "ui_action", null),
            Triple(Level.W, "press_key", "back"),
            Triple(Level.D, "future_danger", null),
        ).forEach { (level, tool, key) ->
            seed()
            assertTrue(invalidatePreparedTargetForMutation(store, level, tool, key))
            assertNull(
                store.current(
                    "com.tencent.mm",
                    "7|id/chat_input|android.widget.EditText|com.tencent.mm|1,2,30,40",
                    "[1,2][30,40]",
                    "ime|0123456789abcdef01234567",
                ),
            )
        }

        seed()
        assertTrue(
            invalidatePreparedTargetForMutation(
                store,
                Level.R,
                "ui_find",
                scrollSearch = true,
            ),
        )
        assertNull(
            store.current(
                "com.tencent.mm",
                "7|id/chat_input|android.widget.EditText|com.tencent.mm|1,2,30,40",
                "[1,2][30,40]",
                "ime|0123456789abcdef01234567",
            ),
        )
    }

    @Test
    fun `type text preserves prepared target only after success on the exact same target`() {
        val before = PreparedTargetEvidence(
            preparedId = 1,
            label = "文件传输助手",
            packageName = "com.tencent.mm",
            focusedInputId = "chat-input",
            bounds = "[1,2][30,40]",
            imeSessionId = "ime|0123456789abcdef01234567",
            preparedAtMs = 1,
            expiresAtMs = 2,
        )
        val input = InputCommitEvidence(
            commitId = 1,
            preview = "x",
            length = 1,
            sha256 = InputCommitEvidence.sha256("x"),
            focusedInputId = "chat-input",
            committedAtMs = 1,
            expiresAtMs = 2,
        )

        assertTrue(preparedTargetSurvivesTypeText(before, before.copy(), input, succeeded = true))
        assertFalse(preparedTargetSurvivesTypeText(before, null, input, succeeded = true))
        assertFalse(
            preparedTargetSurvivesTypeText(
                before,
                before.copy(focusedInputId = "other-input"),
                input,
                succeeded = true,
            ),
        )
        assertFalse(
            preparedTargetSurvivesTypeText(
                before,
                before.copy(imeSessionId = "ime|fedcba9876543210fedcba98"),
                input,
                succeeded = true,
            ),
        )
        assertFalse(
            preparedTargetSurvivesTypeText(
                before,
                before,
                input.copy(focusedInputId = "other-input"),
                succeeded = true,
            ),
        )
        assertFalse(preparedTargetSurvivesTypeText(before, before, input, succeeded = false))
    }

    @Test
    fun `second mutation cannot enter while first waits for human confirmation`() {
        val coordinator = UiMutationCoordinator()
        val firstEntered = CountDownLatch(1)
        val allowFirstToFinish = CountDownLatch(1)
        val secondAttempted = CountDownLatch(1)
        val secondEntered = CountDownLatch(1)
        val order = Collections.synchronizedList(mutableListOf<String>())
        val pool = Executors.newFixedThreadPool(2)

        try {
            val first = pool.submit {
                coordinator.runExclusive {
                    order += "first-enter"
                    firstEntered.countDown()
                    assertTrue(allowFirstToFinish.await(2, TimeUnit.SECONDS))
                    order += "first-exit"
                }
            }
            assertTrue(firstEntered.await(1, TimeUnit.SECONDS))

            val second = pool.submit {
                secondAttempted.countDown()
                coordinator.runExclusive {
                    order += "second-enter"
                    secondEntered.countDown()
                }
            }
            assertTrue(secondAttempted.await(1, TimeUnit.SECONDS))
            assertFalse("确认等待期间第二个 mutator 不得进入", secondEntered.await(150, TimeUnit.MILLISECONDS))

            allowFirstToFinish.countDown()
            first.get(2, TimeUnit.SECONDS)
            second.get(2, TimeUnit.SECONDS)
            assertEquals(listOf("first-enter", "first-exit", "second-enter"), order)
        } finally {
            allowFirstToFinish.countDown()
            pool.shutdownNow()
        }
    }
}
