package dev.magina.gateway.a11y

import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.GatewayError
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test

class FreshActionAtomicityTest {
    @Test
    fun `dense tree fresh capture still increments independent generation`() {
        var captures = 0
        val coordinator = VisionCaptureCoordinator { ++captures }

        val first = coordinator.captureFresh()
        val second = coordinator.captureFresh()

        assertEquals(1, first.payload)
        assertEquals(2, second.payload)
        assertEquals(1L, first.generation)
        assertEquals(2L, second.generation)
        assertEquals(2, captures)
    }

    @Test
    fun `production fresh session carries new capture metadata through dense tree without OCR`() {
        data class DenseSnapshot(
            val elementCount: Int,
            val captureRevision: Long,
            val visionGeneration: Long,
            val pixels: Int,
        )

        var screenSamples = 0
        var ocrCalls = 0
        var revision = 7L
        val session = FreshVisionSession(capture = { ++screenSamples }, currentRevision = { revision })
        fun denseSnapshot(): DenseSnapshot = session.withFreshCapture {
            val capture = requireNotNull(session.current())
            // 12 个 a11y 元素超过融合阈值：真实契约仍携带本次屏幕样本，不调用 OCR。
            DenseSnapshot(
                elementCount = 12,
                captureRevision = capture.revision,
                visionGeneration = capture.generation,
                pixels = capture.payload,
            )
                .also { if (it.elementCount < 5) ocrCalls++ }
        }

        assertEquals(DenseSnapshot(12, 7, 1, 1), denseSnapshot())
        assertEquals(DenseSnapshot(12, 7, 2, 2), denseSnapshot())
        assertEquals(2, screenSamples)
        assertEquals(0, ocrCalls)
    }

    @Test
    fun `fresh session rejects revision changes during screenshot after capture and before return`() {
        fun expectStale(block: () -> Unit) {
            try {
                block()
                fail("expected stale")
            } catch (error: GatewayError) {
                assertEquals(ErrorCode.E_STALE_REF, error.code)
            }
        }

        var duringRevision = 10L
        val during = FreshVisionSession(
            capture = { duringRevision++; "pixels" },
            currentRevision = { duringRevision },
        )
        expectStale { during.withFreshCapture { "snapshot" } }

        var beforeAssemblyRevision = 20L
        val beforeAssembly = FreshVisionSession(
            capture = { "pixels" },
            currentRevision = { beforeAssemblyRevision },
        )
        expectStale {
            beforeAssembly.withFreshCapture {
                beforeAssemblyRevision++ // 截图完成，snapshot/OCR 组装开始前页面变化。
                "snapshot"
            }
        }

        var beforeReturnRevision = 30L
        val beforeReturn = FreshVisionSession(
            capture = { "pixels" },
            currentRevision = { beforeReturnRevision },
        )
        expectStale {
            beforeReturn.withFreshCapture {
                val assembled = "snapshot"
                beforeReturnRevision++ // 组装已完成，但结果返回前变化。
                assembled
            }
        }
    }

    @Test
    fun `final click guard rejects revision foreground overlay and IME changes`() {
        val expected = FreshClickExpectation(7, 42, "com.tencent.mm", imeMustBeHidden = true)
        FreshClickFinalGuard.requireCurrent(
            expected,
            FreshClickCurrent(7, true, 42, "com.tencent.mm", blockingOverlay = false, imeVisible = false),
        )
        val changed = listOf(
            FreshClickCurrent(8, true, 42, "com.tencent.mm", false, false),
            FreshClickCurrent(7, true, 43, "com.tencent.mm", false, false),
            FreshClickCurrent(7, true, 42, "com.android.launcher", false, false),
            FreshClickCurrent(7, false, 42, "com.tencent.mm", false, false),
            FreshClickCurrent(7, true, 42, "com.tencent.mm", true, false),
            FreshClickCurrent(7, true, 42, "com.tencent.mm", false, true),
        )
        changed.forEach { current ->
            try {
                FreshClickFinalGuard.requireCurrent(expected, current)
                fail("expected stale")
            } catch (error: GatewayError) {
                assertEquals(ErrorCode.E_STALE_REF, error.code)
            }
        }
    }

    @Test
    fun `resolve drift in revision overlay IME package or window performs zero actions`() {
        val expected = FreshClickExpectation(7, 42, "com.tencent.mm", imeMustBeHidden = true)
        val valid = FreshClickCurrent(7, true, 42, "com.tencent.mm", false, false)
        val drifted = listOf(
            valid.copy(revision = 8),
            valid.copy(blockingOverlay = true),
            valid.copy(imeVisible = true),
            valid.copy(packageName = "com.android.launcher"),
            valid.copy(windowId = 43),
        )

        drifted.forEach { afterResolve ->
            var actions = 0
            try {
                FreshClickActionExecutor.resolveGuardPerform(
                    expected = expected,
                    resolve = { "resolved-target" },
                    readCurrent = { afterResolve },
                    perform = { actions++; true },
                )
                fail("expected stale")
            } catch (error: GatewayError) {
                assertEquals(ErrorCode.E_STALE_REF, error.code)
            }
            assertEquals(0, actions)
        }
    }

    @Test
    fun `fixed query search focus guard rejects lost or moved editable focus`() {
        val valid = FreshSearchFocusCurrent(
            nodePresent = true,
            focused = true,
            editable = true,
            screenWidth = 1080,
            screenHeight = 2400,
            left = 40,
            top = 80,
            right = 1040,
            bottom = 220,
        )
        assertEquals(true, FreshSearchFocusGuard.isValid(valid))
        assertEquals(false, FreshSearchFocusGuard.isValid(valid.copy(focused = false)))
        assertEquals(false, FreshSearchFocusGuard.isValid(valid.copy(editable = false)))
        assertEquals(false, FreshSearchFocusGuard.isValid(valid.copy(top = 1800, bottom = 1950)))
    }
}
