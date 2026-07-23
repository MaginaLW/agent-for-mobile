package dev.magina.gateway.testing

// debug-only test-control storage test.

import org.junit.Assert.assertFalse
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class AtomicPrivateFileWriterTest {
    @get:Rule
    val temp = TemporaryFolder()

    @Test
    fun `text temp is removed when write fails after creating it`() {
        var created: File? = null
        val writer = AtomicPrivateFileWriter(
            tempIdFactory = { "write-fail" },
            textWriter = { file, text ->
                created = file
                file.writeText(text)
                throw IllegalStateException("write failed")
            },
        )

        expectFailure { writer.writeText(File(temp.root, "state.json"), "value") }

        assertFalse(created!!.exists())
    }

    @Test
    fun `png temp is removed when atomic move fails`() {
        var created: File? = null
        val writer = AtomicPrivateFileWriter(
            tempIdFactory = { "move-fail" },
            bytesWriter = { file, bytes ->
                created = file
                file.writeBytes(bytes)
            },
            mover = { _, _ -> throw IllegalStateException("move failed") },
        )

        expectFailure { writer.writeBytes(File(temp.root, "evidence.png"), byteArrayOf(1, 2)) }

        assertFalse(created!!.exists())
    }

    private fun expectFailure(block: () -> Unit) {
        try {
            block()
            fail("expected failure")
        } catch (_: IllegalStateException) {
            // expected
        }
    }
}
