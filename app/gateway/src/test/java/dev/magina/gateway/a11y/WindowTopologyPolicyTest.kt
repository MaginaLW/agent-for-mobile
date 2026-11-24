package dev.magina.gateway.a11y

import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.GatewayError
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
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

    @Test
    fun `isTransientUnknownMultiWindow only allows single non-empty package paired with blank package`() {
        val singlePlusNull = listOf(
            AppWindowSlice(10, "com.tencent.mm", 0, 0, 1400, 1800),
            AppWindowSlice(11, null, 1400, 0, 2800, 1800),
        )
        assertTrue(isTransientUnknownMultiWindow(singlePlusNull))

        val twoSamePlusBlank = listOf(
            AppWindowSlice(10, "com.tencent.mm", 0, 0, 1400, 1800),
            AppWindowSlice(11, "com.tencent.mm", 400, 200, 1000, 800),
            AppWindowSlice(12, "   ", 1400, 0, 2800, 1800),
        )
        assertTrue(isTransientUnknownMultiWindow(twoSamePlusBlank))

        // 跨双包：立即返回 false（零等待）
        val crossApp = listOf(
            AppWindowSlice(10, "com.xingin.xhs", 0, 0, 1400, 1800),
            AppWindowSlice(12, "com.jingdong.app.mall", 1400, 0, 2800, 1800),
        )
        assertFalse(isTransientUnknownMultiWindow(crossApp))

        // 跨双包 + 空包：仍立即返回 false
        val crossAppWithNull = crossApp + AppWindowSlice(13, null, 100, 100, 500, 500)
        assertFalse(isTransientUnknownMultiWindow(crossAppWithNull))

        // 全空包无已知应用：fail-closed 返回 false
        val allBlank = listOf(
            AppWindowSlice(10, null, 0, 0, 1400, 1800),
            AppWindowSlice(11, "", 1400, 0, 2800, 1800),
        )
        assertFalse(isTransientUnknownMultiWindow(allBlank))

        // 单窗 / 同应用双窗不触发瞬态重读
        assertFalse(isTransientUnknownMultiWindow(listOf(AppWindowSlice(10, "com.tencent.mm", 0, 0, 1400, 1800))))
        assertFalse(
            isTransientUnknownMultiWindow(
                listOf(
                    AppWindowSlice(10, "com.tencent.mm", 0, 0, 1400, 1800),
                    AppWindowSlice(11, "com.tencent.mm", 1400, 0, 2800, 1800),
                ),
            ),
        )
    }

    @Test
    fun `settleSnapshotWindows fails closed with zero wait on cross-app multi-window`() {
        val crossApp = listOf(
            AppWindowSlice(10, "com.xingin.xhs", 0, 0, 1400, 1800),
            AppWindowSlice(12, "com.jingdong.app.mall", 1400, 0, 2800, 1800),
        )
        var reads = 0
        val sleeps = mutableListOf<Long>()
        try {
            settleSnapshotWindows(
                readWindows = {
                    reads += 1
                    crossApp
                },
                extractSlices = { it },
                sleep = { sleeps.add(it) },
            )
            fail("expected E_BLOCKED")
        } catch (error: GatewayError) {
            assertEquals(ErrorCode.E_BLOCKED, error.code)
        }
        assertEquals(1, reads)
        assertTrue(sleeps.isEmpty())
    }

    @Test
    fun `settleSnapshotWindows settles transient single-package plus null window within 4 rereads`() {
        val transientSlices = listOf(
            AppWindowSlice(10, "com.tencent.mm", 0, 0, 1400, 1800),
            AppWindowSlice(11, null, 1400, 0, 2800, 1800),
        )
        val resolvedSameApp = listOf(
            AppWindowSlice(10, "com.tencent.mm", 0, 0, 1400, 1800),
            AppWindowSlice(11, "com.tencent.mm", 1400, 0, 2800, 1800),
        )
        val frames = listOf(transientSlices, transientSlices, resolvedSameApp)
        var index = 0
        val sleeps = mutableListOf<Long>()

        val settled = settleSnapshotWindows(
            readWindows = { frames[index++] },
            extractSlices = { it },
            sleep = { sleeps.add(it) },
        )

        assertEquals(WindowTopology.SAME_APP_MULTI, settled.topology)
        assertEquals(resolvedSameApp, settled.slices)
        assertEquals(listOf(80L, 80L), sleeps)
    }

    @Test
    fun `settleSnapshotWindows stops immediately if cross-app appears during reread`() {
        val transientSlices = listOf(
            AppWindowSlice(10, "com.tencent.mm", 0, 0, 1400, 1800),
            AppWindowSlice(11, null, 1400, 0, 2800, 1800),
        )
        val crossApp = listOf(
            AppWindowSlice(10, "com.tencent.mm", 0, 0, 1400, 1800),
            AppWindowSlice(11, "com.jingdong.app.mall", 1400, 0, 2800, 1800),
        )
        val frames = listOf(transientSlices, crossApp)
        var index = 0
        val sleeps = mutableListOf<Long>()

        try {
            settleSnapshotWindows(
                readWindows = { frames[index++] },
                extractSlices = { it },
                sleep = { sleeps.add(it) },
            )
            fail("expected E_BLOCKED")
        } catch (error: GatewayError) {
            assertEquals(ErrorCode.E_BLOCKED, error.code)
        }
        assertEquals(listOf(80L), sleeps)
        assertEquals(2, index)
    }

    @Test
    fun `settleSnapshotWindows throws E_BLOCKED after 4 rereads if unknown package persists`() {
        val persistentUnknown = listOf(
            AppWindowSlice(10, "com.tencent.mm", 0, 0, 1400, 1800),
            AppWindowSlice(11, null, 1400, 0, 2800, 1800),
        )
        var reads = 0
        val sleeps = mutableListOf<Long>()

        try {
            settleSnapshotWindows(
                readWindows = {
                    reads += 1
                    persistentUnknown
                },
                extractSlices = { it },
                sleep = { sleeps.add(it) },
            )
            fail("expected E_BLOCKED")
        } catch (error: GatewayError) {
            assertEquals(ErrorCode.E_BLOCKED, error.code)
        }
        assertEquals(5, reads)
        assertEquals(listOf(80L, 80L, 80L, 80L), sleeps)
    }
}
