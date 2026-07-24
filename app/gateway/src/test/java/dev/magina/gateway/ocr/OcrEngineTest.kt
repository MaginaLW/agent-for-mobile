package dev.magina.gateway.ocr

import org.junit.Assert.assertEquals
import org.junit.Test

class OcrEngineTest {

    @Test
    fun `identical rects overlap completely`() {
        assertEquals(1.0, OcrEngine.overlapRatio(0, 0, 100, 50, 0, 0, 100, 50), 1e-9)
    }

    @Test
    fun `disjoint rects have zero overlap`() {
        assertEquals(0.0, OcrEngine.overlapRatio(0, 0, 10, 10, 20, 20, 30, 30), 1e-9)
    }

    @Test
    fun `touching but non-overlapping edges have zero overlap`() {
        assertEquals(0.0, OcrEngine.overlapRatio(0, 0, 10, 10, 10, 0, 20, 10), 1e-9)
    }

    @Test
    fun `partial overlap computes intersection over union`() {
        // a = [0,0]-[10,10] area 100; b = [5,5]-[15,15] area 100; intersection = [5,5]-[10,10] area 25.
        // union = 100 + 100 - 25 = 175; IoU = 25/175.
        val ratio = OcrEngine.overlapRatio(0, 0, 10, 10, 5, 5, 15, 15)
        assertEquals(25.0 / 175.0, ratio, 1e-9)
    }

    @Test
    fun `one rect fully containing another`() {
        // a = [0,0]-[20,20] area 400; b = [5,5]-[10,10] area 25, fully inside a.
        // intersection = 25; union = 400 + 25 - 25 = 400; IoU = 25/400.
        val ratio = OcrEngine.overlapRatio(0, 0, 20, 20, 5, 5, 10, 10)
        assertEquals(25.0 / 400.0, ratio, 1e-9)
    }

    @Test
    fun `zero area rect never overlaps`() {
        assertEquals(0.0, OcrEngine.overlapRatio(0, 0, 0, 0, 0, 0, 10, 10), 1e-9)
    }
}
