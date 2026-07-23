package dev.magina.gateway.a11y

import org.junit.Assert.assertEquals
import org.junit.Test

class FreshVisionCacheTest {
    @Test
    fun `force fresh bypasses reusable cached OCR result`() {
        val cache = FreshVisionCache<Int>()
        var loads = 0
        fun read(forceFresh: Boolean) = cache.getOrLoad(
            forceFresh = forceFresh,
            reusable = { true },
            loader = { ++loads },
        )

        assertEquals(1, read(forceFresh = false))
        assertEquals(1, read(forceFresh = false))
        assertEquals(2, read(forceFresh = true))
        assertEquals(2, loads)
    }
}
