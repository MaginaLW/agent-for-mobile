package dev.magina.gateway.testing

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ConfirmationIdTest {
    @Test
    fun `confirmation ids are short non sensitive and unique`() {
        val ids = List(128) { ConfirmationIdGenerator.next() }

        assertEquals(ids.size, ids.toSet().size)
        assertTrue(ids.all { it.matches(Regex("^[a-f0-9]{12}$")) })
    }
}
