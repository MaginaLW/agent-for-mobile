package dev.magina.gateway.a11y

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SnapshotRefRegistryTest {

    @Test
    fun `下一次 snapshot 不复用 a11y 或 OCR ref 且旧 ref 明确 stale`() {
        val refs = SnapshotRefRegistry<String>(sessionId = "testsession")
        val first = refs.beginSnapshot(revision = 7)
        val oldA11y = refs.bind(first, UiRefSource.A11Y, 1, "old-node")
        val oldOcr = refs.bind(first, UiRefSource.OCR, 1, "old-ocr")

        val second = refs.beginSnapshot(revision = 7)
        val newA11y = refs.bind(second, UiRefSource.A11Y, 1, "new-node")
        val newOcr = refs.bind(second, UiRefSource.OCR, 1, "new-ocr")

        assertNotEquals(oldA11y, newA11y)
        assertNotEquals(oldOcr, newOcr)
        assertEquals(UiRefLookupState.STALE, refs.lookup(oldA11y).state)
        assertEquals(UiRefLookupState.STALE, refs.lookup(oldOcr).state)
        assertEquals("new-node", refs.lookup(newA11y).value)
        assertEquals("new-ocr", refs.lookup(newOcr).value)
    }

    @Test
    fun `服务进程命名空间不同所以重启后的旧 ref 不会命中新节点`() {
        val beforeRestart = SnapshotRefRegistry<String>(sessionId = "oldsession")
        val oldBatch = beforeRestart.beginSnapshot(revision = 1)
        val oldRef = beforeRestart.bind(oldBatch, UiRefSource.A11Y, 1, "old-node")

        val afterRestart = SnapshotRefRegistry<String>(sessionId = "newsession")
        val newBatch = afterRestart.beginSnapshot(revision = 1)
        val newRef = afterRestart.bind(newBatch, UiRefSource.A11Y, 1, "new-node")

        assertNotEquals(oldRef, newRef)
        val lookup = afterRestart.lookup(oldRef)
        assertEquals(UiRefLookupState.MISSING, lookup.state)
        assertNull(lookup.value)
    }

    @Test
    fun `只能向当前 batch 绑定并且同一 ref 不能覆盖`() {
        val refs = SnapshotRefRegistry<String>(sessionId = "testsession")
        val old = refs.beginSnapshot(revision = 1)
        refs.bind(old, UiRefSource.A11Y, 1, "one")
        val current = refs.beginSnapshot(revision = 2)

        val oldFailure = runCatching { refs.bind(old, UiRefSource.A11Y, 2, "stale") }.exceptionOrNull()
        assertTrue(oldFailure is IllegalStateException)

        refs.bind(current, UiRefSource.A11Y, 1, "current")
        val duplicateFailure = runCatching {
            refs.bind(current, UiRefSource.A11Y, 1, "overwrite")
        }.exceptionOrNull()
        assertTrue(duplicateFailure is IllegalStateException)
        assertEquals("current", refs.currentEntries().single().second)
    }
}
