package dev.magina.gateway.tablet.c1b

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class C1bPendingStartRegistryTest {
    @Test
    fun claimIsAtomicAndAlwaysWipesRawInput() {
        val registry = C1bPendingStartRegistry()
        val ticket = registry.register(ENVELOPE) {}
        val raw = byteArrayOf(1, 2, 3)
        var calls = 0

        assertTrue(ticket.claimStart(raw) { calls += 1 })
        assertTrue(raw.all { it == 0.toByte() })
        assertFalse(ticket.claimFailure { calls += 1 })
        assertEquals(1, calls)
        ticket.complete()
        assertEquals(C1bPendingAwait.NONE, registry.await(KEY, 0))
    }

    @Test
    fun abortCancelsOnlyExactOpenTicketAndCompletesWaiter() {
        val registry = C1bPendingStartRegistry()
        var cancelCalls = 0
        registry.register(ENVELOPE) { cancelCalls += 1 }
        val other = C1bSessionKey("tl1-c1b-pending-other", "n-" + "2".repeat(32))

        assertNull(registry.cancel(other) { "wrong" })
        assertEquals("cancelled", registry.cancel(KEY) { "cancelled" })
        assertEquals(1, cancelCalls)
        assertEquals(C1bPendingAwait.NONE, registry.await(KEY, 0))
    }

    private companion object {
        val KEY = C1bSessionKey("tl1-c1b-pending", "n-" + "1".repeat(32))
        val ENVELOPE = C1bStartEnvelope(
            KEY,
            TABLET_C1B_EXPECTED_TITLE_HASH,
            "a".repeat(40),
            "sha256:" + "b".repeat(64),
        )
    }
}
