package dev.magina.gateway.vision

import dev.magina.gateway.a11y.AppWindowSlice
import dev.magina.gateway.a11y.WindowTopology
import dev.magina.gateway.ocr.OcrEngine
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class OcrTilePlannerTest {
    private val pkg = "com.tencent.mm"
    private val pa2553Left = AppWindowSlice(358, pkg, 0, 0, 923, 1968)
    private val pa2553Right = AppWindowSlice(384, pkg, 927, 0, 2800, 1968)
    private val pa2553Slices = listOf(pa2553Left, pa2553Right)

    @Test
    fun `single-window phones and small screens bypass tiled ocr`() {
        assertEquals(0.5f, OcrEngine.MIN_CONF, 0f)

        // 单窗手机（即使长边 2800px）绝不进入分窗切片路径
        val singlePhone = planOcrTiles(
            topology = WindowTopology.SINGLE,
            sparseSlices = listOf(AppWindowSlice(1, pkg, 0, 0, 1260, 2800)),
            fullWidth = 1260,
            fullHeight = 2800,
            imeTop = Int.MAX_VALUE,
        )
        assertTrue(singlePhone.isEmpty())

        // 非 SAME_APP_MULTI 拓扑（NONE / CROSS_OR_UNKNOWN_MULTI）返回空
        assertTrue(planOcrTiles(WindowTopology.NONE, pa2553Slices, 2800, 1968, Int.MAX_VALUE).isEmpty())
        assertTrue(
            planOcrTiles(WindowTopology.CROSS_OR_UNKNOWN_MULTI, pa2553Slices, 2800, 1968, Int.MAX_VALUE).isEmpty(),
        )

        // 小屏模拟器（长边 <= 1600px，含边界 1600px）保持原整屏路径
        val smallSlices = listOf(
            AppWindowSlice(10, pkg, 0, 0, 560, 900),
            AppWindowSlice(20, pkg, 580, 0, 1600, 900),
        )
        assertTrue(planOcrTiles(WindowTopology.SAME_APP_MULTI, smallSlices, 1600, 900, Int.MAX_VALUE).isEmpty())
    }

    @Test
    fun `PA2553 2800x1968 hidden IME plans 4 vertical-split tiles with 80px overlap and disjoint ownership`() {
        val tiles = planOcrTiles(
            topology = WindowTopology.SAME_APP_MULTI,
            sparseSlices = pa2553Slices,
            fullWidth = 2800,
            fullHeight = 1968,
            imeTop = Int.MAX_VALUE,
        )
        assertEquals(4, tiles.size)

        // 左窗上下两片：923x1064，归属带 [0, 984) 与 [984, 1968]
        assertEquals(
            OcrTile(358, TileRect(0, 0, 923, 1064), ownTop = 0, ownBottom = 984, ownBottomInclusive = false),
            tiles[0],
        )
        assertEquals(
            OcrTile(358, TileRect(0, 904, 923, 1968), ownTop = 984, ownBottom = 1968, ownBottomInclusive = true),
            tiles[1],
        )

        // 右窗上下两片：1873x1064，归属带 [0, 984) 与 [984, 1968]
        assertEquals(
            OcrTile(384, TileRect(927, 0, 2800, 1064), ownTop = 0, ownBottom = 984, ownBottomInclusive = false),
            tiles[2],
        )
        assertEquals(
            OcrTile(384, TileRect(927, 904, 2800, 1968), ownTop = 984, ownBottom = 1968, ownBottomInclusive = true),
            tiles[3],
        )
    }

    @Test
    fun `PA2553 2800x1968 visible IME at y=1187 plans 2 clipped full-pane tiles`() {
        val tiles = planOcrTiles(
            topology = WindowTopology.SAME_APP_MULTI,
            sparseSlices = pa2553Slices,
            fullWidth = 2800,
            fullHeight = 1968,
            imeTop = 1187,
        )
        assertEquals(2, tiles.size)
        assertEquals(
            OcrTile(358, TileRect(0, 0, 923, 1187), ownTop = 0, ownBottom = 1187, ownBottomInclusive = true),
            tiles[0],
        )
        assertEquals(
            OcrTile(384, TileRect(927, 0, 2800, 1187), ownTop = 0, ownBottom = 1187, ownBottomInclusive = true),
            tiles[1],
        )
    }

    @Test
    fun `seam overlap deduplicates strictly at midY with zero duplicates, zero drops, and exact 0px offset`() {
        val tiles = planOcrTiles(
            topology = WindowTopology.SAME_APP_MULTI,
            sparseSlices = pa2553Slices,
            fullWidth = 2800,
            fullHeight = 1968,
            imeTop = Int.MAX_VALUE,
        )
        val rightTop = tiles[2]    // crop [927, 0, 2800, 1064], owns [0, 984)
        val rightBottom = tiles[3] // crop [927, 904, 2800, 1968], owns [984, 1968]

        // 模拟 3 条文字同时出现在两片的 80px 重叠区 [904, 1064]：
        // - lineAbove: 整屏 y=[940, 980], centerY=960 (< 984 -> 归上片)
        // - lineExactSeam: 整屏 y=[964, 1004], centerY=984 (== midY -> 严格归下片)
        // - lineBelow: 整屏 y=[990, 1030], centerY=1010 (> 984 -> 归下片)
        // 另加一条远非接缝的右窗输入栏/标题行验证精确 (+927, +0) 与 (+927, +904) 偏移
        val rawTop = listOf(
            TileOcrLine("标题", 0.90f, TileRect(100, 80, 300, 124)),
            TileOcrLine("接缝上方", 0.88f, TileRect(100, 940, 400, 980)),
            TileOcrLine("正好压线", 0.87f, TileRect(100, 964, 400, 1004)),
            TileOcrLine("接缝下方", 0.86f, TileRect(100, 990, 400, 1030)),
        )
        val rawBottom = listOf(
            TileOcrLine("接缝上方", 0.88f, TileRect(100, 940 - 904, 400, 980 - 904)),
            TileOcrLine("正好压线", 0.87f, TileRect(100, 964 - 904, 400, 1004 - 904)),
            TileOcrLine("接缝下方", 0.86f, TileRect(100, 990 - 904, 400, 1030 - 904)),
            TileOcrLine("发送", 0.71f, TileRect(1600, 1840 - 904, 1720, 1878 - 904)),
        )

        val keptTop = offsetAndFilterTileLines(rightTop, rawTop)
        val keptBottom = offsetAndFilterTileLines(rightBottom, rawBottom)

        assertEquals(listOf("标题", "接缝上方"), keptTop.map { it.text })
        assertEquals(listOf("正好压线", "接缝下方", "发送"), keptBottom.map { it.text })

        val combined = keptTop + keptBottom
        assertEquals(5, combined.size)
        assertEquals(5, combined.map { it.text }.distinct().size)

        // 逐像素精确偏移验证（0px 误差）
        assertEquals(TileRect(1027, 80, 1227, 124), keptTop[0].bounds)
        assertEquals(TileRect(1027, 940, 1327, 980), keptTop[1].bounds)
        assertEquals(TileRect(1027, 964, 1327, 1004), keptBottom[0].bounds)
        assertEquals(TileRect(1027, 990, 1327, 1030), keptBottom[1].bounds)
        assertEquals(TileRect(2527, 1840, 2647, 1878), keptBottom[2].bounds)

        // 严格边界：centerY == midY 仅归下片，不归上片
        assertFalse(rightTop.ownsCenterY(984))
        assertTrue(rightBottom.ownsCenterY(984))
    }

    @Test
    fun `per-window sparsity triggers tiled ocr strictly for sparse left pane even when right Flutter pane has 12 nodes`() {
        val sparseIds = sparseWindowIds(
            slices = pa2553Slices,
            fgCountByWin = mapOf(384 to 12), // 右窗 Flutter 贡献 12 个 a11y 节点，左窗 LauncherUI 贡献 0
            threshold = 5,
        )
        assertEquals(setOf(358), sparseIds)

        val sparseSlices = pa2553Slices.filter { it.windowId in sparseIds }
        val tiles = planOcrTiles(
            topology = WindowTopology.SAME_APP_MULTI,
            sparseSlices = sparseSlices,
            fullWidth = 2800,
            fullHeight = 1968,
            imeTop = Int.MAX_VALUE,
        )
        assertEquals(2, tiles.size)
        assertTrue(tiles.all { it.windowId == 358 })
        assertEquals(TileRect(0, 0, 923, 1064), tiles[0].crop)
        assertEquals(TileRect(0, 904, 923, 1968), tiles[1].crop)

        // 双窗均 >=5 节点时无需 OCR
        assertTrue(sparseWindowIds(pa2553Slices, mapOf(358 to 5, 384 to 12), threshold = 5).isEmpty())
    }

    @Test
    fun `ocr cache signature distinguishes imeTop and sparse slice changes`() {
        val hiddenAll = buildOcrCacheSignature(WindowTopology.SAME_APP_MULTI, pa2553Slices, Int.MAX_VALUE)
        val visibleAll = buildOcrCacheSignature(WindowTopology.SAME_APP_MULTI, pa2553Slices, 1187)
        val hiddenLeftOnly = buildOcrCacheSignature(WindowTopology.SAME_APP_MULTI, listOf(pa2553Left), Int.MAX_VALUE)
        val reorderedAll = buildOcrCacheSignature(WindowTopology.SAME_APP_MULTI, listOf(pa2553Right, pa2553Left), Int.MAX_VALUE)

        assertEquals(hiddenAll, reorderedAll)
        assertNotEquals(hiddenAll, visibleAll)
        assertNotEquals(hiddenAll, hiddenLeftOnly)
    }

    @Test
    fun `appWindowElementCap keeps single-window unchanged and reserves sparse-pane OCR slots in SAME_APP_MULTI`() {
        // 单窗 / 非 SAME_APP_MULTI / <=1 应用窗：100% 沿用 maxElements
        assertEquals(200, appWindowElementCap(WindowTopology.SINGLE, appWindowCount = 1, maxElements = 200))
        assertEquals(400, appWindowElementCap(WindowTopology.SINGLE, appWindowCount = 1, maxElements = 400))
        assertEquals(200, appWindowElementCap(WindowTopology.NONE, appWindowCount = 0, maxElements = 200))
        assertEquals(200, appWindowElementCap(WindowTopology.CROSS_OR_UNKNOWN_MULTI, appWindowCount = 2, maxElements = 200))
        assertEquals(400, appWindowElementCap(WindowTopology.SAME_APP_MULTI, appWindowCount = 1, maxElements = 400))

        // PA2553 双窗平行视界：ui_find(400) -> 150/窗（保留 >=100 槽给稀疏窗 OCR）；ui_snapshot(200) -> 75/窗（保留 >=50 槽）
        val findCap = appWindowElementCap(WindowTopology.SAME_APP_MULTI, appWindowCount = 2, maxElements = 400)
        assertEquals(150, findCap)
        assertTrue(400 - findCap * 2 >= 100)

        val snapCap = appWindowElementCap(WindowTopology.SAME_APP_MULTI, appWindowCount = 2, maxElements = 200)
        assertEquals(75, snapCap)
        assertTrue(200 - snapCap * 2 >= 50)

        // 3 应用窗也保持预留 >= 1/4 槽位
        assertEquals(100, appWindowElementCap(WindowTopology.SAME_APP_MULTI, appWindowCount = 3, maxElements = 400))

        // 边界值：极小正预算下至少 1；非正预算返回 0
        assertEquals(1, appWindowElementCap(WindowTopology.SAME_APP_MULTI, appWindowCount = 2, maxElements = 2))
        assertEquals(1, appWindowElementCap(WindowTopology.SAME_APP_MULTI, appWindowCount = 2, maxElements = 1))
        assertEquals(0, appWindowElementCap(WindowTopology.SAME_APP_MULTI, appWindowCount = 2, maxElements = 0))
        assertEquals(0, appWindowElementCap(WindowTopology.SAME_APP_MULTI, appWindowCount = 2, maxElements = -10))

        // 稠密右窗（如 500 个 Flutter a11y 节点）+ 16 个系统栏节点，在单窗限额下仍为左窗 OCR 留足 234 槽位
        val systemBarNodes = 16
        val denseRightNodes = 500
        val cappedRight = minOf(denseRightNodes, findCap)
        val remainingForLeftOcr = 400 - systemBarNodes - cappedRight
        assertEquals(234, remainingForLeftOcr)
    }
}
