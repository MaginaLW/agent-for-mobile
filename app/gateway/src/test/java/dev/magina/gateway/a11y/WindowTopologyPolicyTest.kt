package dev.magina.gateway.a11y

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class WindowTopologyPolicyTest {

    @Test
    fun `empty and zero-area windows classify as NONE while single window classifies as SINGLE`() {
        assertEquals(WindowTopology.NONE, classifyWindowTopology(emptyList()))
        assertEquals(
            WindowTopology.NONE,
            classifyWindowTopology(listOf(AppWindowSlice(1, "com.xingin.xhs", 0, 0, 0, 100))),
        )
        assertEquals(
            WindowTopology.SINGLE,
            classifyWindowTopology(
                listOf(
                    AppWindowSlice(1, "com.xingin.xhs", 0, 0, 1200, 800),
                    AppWindowSlice(2, null, 0, 0, 0, 0),
                ),
            ),
        )
    }

    @Test
    fun `same package multi-pane classifies as SAME_APP_MULTI while distinct or unknown package fails closed`() {
        val sameApp = listOf(
            AppWindowSlice(10, "com.xingin.xhs", 0, 0, 1400, 1800),
            AppWindowSlice(11, "com.xingin.xhs", 1400, 0, 2800, 1800),
        )
        assertEquals(WindowTopology.SAME_APP_MULTI, classifyWindowTopology(sameApp))

        val crossApp = listOf(
            AppWindowSlice(10, "com.xingin.xhs", 0, 0, 1400, 1800),
            AppWindowSlice(12, "com.jingdong.app.mall", 1400, 0, 2800, 1800),
        )
        assertEquals(WindowTopology.CROSS_OR_UNKNOWN_MULTI, classifyWindowTopology(crossApp))

        val unknownRoot = listOf(
            AppWindowSlice(10, "com.tencent.mm", 0, 0, 1400, 1800),
            AppWindowSlice(13, null, 1400, 0, 2800, 1800),
        )
        assertEquals(WindowTopology.CROSS_OR_UNKNOWN_MULTI, classifyWindowTopology(unknownRoot))
    }

    @Test
    fun `assignWindowPanes labels horizontal vertical overlapping and single slices`() {
        val horizontal = listOf(
            AppWindowSlice(20, "com.xingin.xhs", 1400, 0, 2800, 1800),
            AppWindowSlice(10, "com.xingin.xhs", 0, 0, 1400, 1800),
        )
        assertEquals(mapOf(10 to "left", 20 to "right"), assignWindowPanes(horizontal))

        val threeHorizontal = listOf(
            AppWindowSlice(1, "com.example.app", 0, 0, 800, 1600),
            AppWindowSlice(2, "com.example.app", 800, 0, 1800, 1600),
            AppWindowSlice(3, "com.example.app", 1800, 0, 2800, 1600),
        )
        assertEquals(
            mapOf(1 to "left", 2 to "middle", 3 to "right"),
            assignWindowPanes(threeHorizontal),
        )

        val vertical = listOf(
            AppWindowSlice(30, "com.example.app", 0, 900, 1800, 1800),
            AppWindowSlice(31, "com.example.app", 0, 0, 1800, 900),
        )
        assertEquals(mapOf(31 to "top", 30 to "bottom"), assignWindowPanes(vertical))

        val centeredDialog = listOf(
            AppWindowSlice(40, "com.example.app", 0, 0, 2800, 1800),
            AppWindowSlice(41, "com.example.app", 400, 300, 2400, 1500),
        )
        assertEquals(mapOf(40 to "full", 41 to "full"), assignWindowPanes(centeredDialog))
        assertEquals(
            mapOf(1 to "full"),
            assignWindowPanes(listOf(AppWindowSlice(1, "com.example.app", 0, 0, 2800, 1800))),
        )
    }

    @Test
    fun `matchSliceForPoint selects containing pane and prefers smaller nested dialog`() {
        val panes = listOf(
            AppWindowSlice(10, "com.xingin.xhs", 0, 0, 1400, 1800),
            AppWindowSlice(20, "com.xingin.xhs", 1400, 0, 2800, 1800),
        )
        assertEquals(10, matchSliceForPoint(panes, 700, 500)?.windowId)
        assertEquals(20, matchSliceForPoint(panes, 2000, 500)?.windowId)
        assertNull(matchSliceForPoint(panes, 3000, 500))

        val nested = listOf(
            AppWindowSlice(100, "com.example.app", 0, 0, 2800, 1800),
            AppWindowSlice(101, "com.example.app", 600, 400, 2200, 1400),
        )
        assertEquals(101, matchSliceForPoint(nested, 1400, 900)?.windowId)
        assertEquals(100, matchSliceForPoint(nested, 100, 100)?.windowId)
    }
}
