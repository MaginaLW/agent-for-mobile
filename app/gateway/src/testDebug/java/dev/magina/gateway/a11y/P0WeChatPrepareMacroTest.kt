package dev.magina.gateway.a11y

// debug-only macro contract tests.

import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.GatewayError
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class P0WeChatPrepareMacroTest {

    @Test
    fun `rejects unknown foreground before taking a snapshot`() {
        val adapter = FakeAdapter(foregrounds = mutableListOf(P0MacroForeground(false, "com.tencent.mm")))

        val error = expectError(ErrorCode.E_BLOCKED) { macro(adapter).run() }

        assertTrue(error.message.orEmpty().contains("已知微信前台"))
        assertEquals(0, adapter.snapshotCalls)
    }

    @Test
    fun `rejects known non-WeChat foreground`() {
        val adapter = FakeAdapter(foregrounds = mutableListOf(P0MacroForeground(true, "com.android.launcher")))

        expectError(ErrorCode.E_BLOCKED) { macro(adapter).run() }

        assertEquals(0, adapter.clicks.size)
    }

    @Test
    fun `fails closed when search entry is absent`() {
        val adapter = FakeAdapter(
            snapshots = mutableListOf(snapshot(element("title", "微信", centerX = 500, centerY = 100))),
        )

        val error = expectError(ErrorCode.E_BLOCKED) { macro(adapter).run() }

        assertTrue(error.message.orEmpty().contains("非敏感"))
        assertEquals(emptyList<String>(), adapter.clicks)
    }

    @Test
    fun `same target text in message body cannot impersonate toolbar title`() {
        val otherConversation = snapshot(
            element("toolbar", "张三", source = "ocr", confidence = 0.94, centerX = 500, centerY = 100),
            element("message", "文件传输助手", source = "ocr", confidence = 0.93, centerX = 500, centerY = 700),
        )
        val adapter = FakeAdapter(snapshots = mutableListOf(otherConversation))

        expectError(ErrorCode.E_BLOCKED) { macro(adapter).run() }

        assertEquals(0, adapter.probeCalls)
    }

    @Test
    fun `low confidence search ref is never clicked`() {
        val list = snapshot(
            element("title", "微信", centerX = 500, centerY = 100),
            element("search", "搜索", source = "ocr", confidence = 0.64, centerX = 500, centerY = 260),
        )
        val adapter = FakeAdapter(snapshots = mutableListOf(list))

        expectError(ErrorCode.E_BLOCKED) { macro(adapter).run() }

        assertEquals(emptyList<String>(), adapter.clicks)
    }

    @Test
    fun `search click must report success`() {
        val adapter = FakeAdapter(
            snapshots = mutableListOf(chatListWithSearch()),
            clickResults = mutableListOf(false),
        )

        val error = expectError(ErrorCode.E_VERIFY_FAIL) { macro(adapter).run() }

        assertTrue(error.message.orEmpty().contains("搜索入口"))
        assertEquals(listOf("search"), adapter.clicks)
    }

    @Test
    fun `stage ref action rejects page change or popup between snapshot and click`() {
        val original = chatListWithSearch().copy(visionGeneration = 3)
        val expected = P0StageRefActionValidator.build(P0RefStage.SEARCH_ENTRY, original)
        val changed = snapshot(
            element("title", "通讯录", centerX = 500, centerY = 100),
            visionGeneration = 4,
        )
        val popup = chatListWithSearch().copy(
            visionGeneration = 4,
            elements = chatListWithSearch().elements +
                element("danger", "请输入支付密码", centerX = 500, centerY = 700),
        )

        expectError(ErrorCode.E_STALE_REF) {
            P0StageRefActionValidator.revalidate(
                expected, changed, P0MacroForeground(true, P0_WECHAT_PACKAGE), emptyList(),
            )
        }
        expectError(ErrorCode.E_STALE_REF) {
            P0StageRefActionValidator.revalidate(
                expected, popup, P0MacroForeground(true, P0_WECHAT_PACKAGE), emptyList(),
            )
        }
    }

    @Test
    fun `times out when search surface postcondition never appears`() {
        val adapter = FakeAdapter(
            snapshots = mutableListOf(chatListWithSearch()),
            repeatedSnapshot = chatListWithSearch(),
        )

        val error = expectError(ErrorCode.E_TIMEOUT) { macro(adapter).run() }

        assertTrue(error.message.orEmpty().contains("搜索页"))
        assertEquals(listOf("search"), adapter.clicks)
    }

    @Test
    fun `times out when target conversation never appears after search opens`() {
        val searchSurface = snapshot(
            element("search-input", "", role = "input", centerX = 500, centerY = 110),
            element("cancel", "取消", centerX = 900, centerY = 110),
        )
        val adapter = FakeAdapter(
            snapshots = mutableListOf(chatListWithSearch(), searchSurface),
            repeatedSnapshot = searchSurface,
        )

        val error = expectError(ErrorCode.E_TIMEOUT) { macro(adapter).run() }

        assertTrue(error.message.orEmpty().contains("文件传输助手"))
        assertEquals(listOf("search"), adapter.clicks)
    }

    @Test
    fun `low confidence target ref is never clicked`() {
        val searchSurface = snapshot(
            element("search-input", "", role = "input", centerX = 500, centerY = 110),
            element("cancel", "取消", centerX = 900, centerY = 110),
        )
        val lowTarget = snapshot(
            element("search-input", "", role = "input", centerX = 500, centerY = 110),
            element(
                "target", "文件传输助手", source = "ocr", confidence = 0.64,
                centerX = 220, centerY = 520,
            ),
        )
        val adapter = FakeAdapter(
            snapshots = mutableListOf(chatListWithSearch(), searchSurface, lowTarget),
            repeatedSnapshot = lowTarget,
        )

        expectError(ErrorCode.E_TIMEOUT) { macro(adapter).run() }

        assertEquals(listOf("search"), adapter.clicks)
        assertEquals(1, adapter.fixedQueryCalls)
    }

    @Test
    fun `fixed query rejects conversation page and non-editable search focus`() {
        val ready = P0MacroFocus(
            true, true, true, "search", editable = true, stage = P0ElementStage.SEARCH,
        )
        expectError(ErrorCode.E_BLOCKED) {
            P0FixedQueryValidator.requireAllowed(
                conversationSnapshot(), P0MacroForeground(true, P0_WECHAT_PACKAGE), ready, emptyList(),
            )
        }
        val search = snapshot(
            element("search-input", "", role = "input", centerX = 500, centerY = 110),
            element("cancel", "取消", centerX = 900, centerY = 110),
        )
        expectError(ErrorCode.E_BLOCKED) {
            P0FixedQueryValidator.requireAllowed(
                search,
                P0MacroForeground(true, P0_WECHAT_PACKAGE),
                ready.copy(editable = false),
                emptyList(),
            )
        }
    }

    @Test
    fun `sensitive semantics appearing during navigation stop before target click`() {
        val blockedSearchSurface = snapshot(
            element("search-input", "", role = "input", centerX = 500, centerY = 110),
            element("cancel", "取消", centerX = 900, centerY = 110),
            element("danger", "请输入支付密码", centerX = 500, centerY = 700),
            element("target", "文件传输助手", centerX = 220, centerY = 900),
        )
        val adapter = FakeAdapter(
            snapshots = mutableListOf(chatListWithSearch(), blockedSearchSurface),
        )

        expectError(ErrorCode.E_BLOCKED) { macro(adapter).run() }

        assertEquals(listOf("search"), adapter.clicks)
    }

    @Test
    fun `target conversation click must report success`() {
        val list = chatListWithTarget()
        val adapter = FakeAdapter(snapshots = mutableListOf(list), clickResults = mutableListOf(false))

        val error = expectError(ErrorCode.E_VERIFY_FAIL) { macro(adapter).run() }

        assertTrue(error.message.orEmpty().contains("目标会话"))
        assertEquals(listOf("target"), adapter.clicks)
    }

    @Test
    fun `times out unless target click reaches conversation-title postcondition`() {
        val list = chatListWithTarget()
        val adapter = FakeAdapter(snapshots = mutableListOf(list), repeatedSnapshot = list)

        val error = expectError(ErrorCode.E_TIMEOUT) { macro(adapter).run() }

        assertTrue(error.message.orEmpty().contains("会话页"))
        assertEquals(listOf("target"), adapter.clicks)
    }

    @Test
    fun `input ref click is used before coordinate fallback`() {
        val conversation = conversationSnapshot(
            element("input", "", role = "input", centerX = 500, centerY = 1750),
        )
        val adapter = FakeAdapter(
            snapshots = mutableListOf(conversation),
            focusStates = stableFocus("fingerprint-a"),
        )

        val result = macro(adapter).run()

        assertEquals(listOf("input"), adapter.clicks)
        assertEquals(0, adapter.probeCalls)
        assertFalse(result.usedCoordinateFallback)
    }

    @Test
    fun `input ref click failure does not fall back to coordinates`() {
        val conversation = conversationSnapshot(
            element("input", "", role = "input", centerX = 500, centerY = 1750),
        )
        val adapter = FakeAdapter(
            snapshots = mutableListOf(conversation),
            clickResults = mutableListOf(false),
        )

        expectError(ErrorCode.E_VERIFY_FAIL) { macro(adapter).run() }

        assertEquals(0, adapter.probeCalls)
    }

    @Test
    fun `low confidence OCR input ref is never clicked or probed`() {
        val conversation = conversationSnapshot(
            element(
                "input", "输入消息", role = "input", source = "ocr", confidence = 0.64,
                centerX = 500, centerY = 1_780,
            ),
        )
        val adapter = FakeAdapter(snapshots = mutableListOf(conversation))

        expectError(ErrorCode.E_BLOCKED) { macro(adapter).run() }

        assertEquals(emptyList<String>(), adapter.clicks)
        assertEquals(0, adapter.probeCalls)
    }

    @Test
    fun `root-null blank field with OCR title only may use one center safe probe`() {
        val titleOnly = snapshot(
            element(
                "o-title", "文件传输助手", source = "ocr", confidence = 0.91,
                centerX = 500, centerY = 100,
            ),
            element(
                "ordinary-message", "昨日文件已收到", source = "ocr", confidence = 0.83,
                centerX = 500, centerY = 800,
            ),
            revision = 30,
        )
        val adapter = FakeAdapter(
            snapshots = mutableListOf(titleOnly),
            focusStates = stableFocus("fingerprint-a"),
        )

        val result = macro(adapter).run()

        assertEquals(1, adapter.probeCalls)
        assertTrue(result.usedCoordinateFallback)
        val probe = adapter.lastProbe ?: throw AssertionError("missing probe")
        assertTrue(probe.region.contains(probe.x, probe.y))
        assertTrue(probe.region.left >= 200)
        assertTrue(probe.region.right <= 800)
        assertTrue(probe.region.top >= 1_600)
        assertTrue(adapter.forceFreshCalls >= 2)
    }

    @Test
    fun `coordinate probe rejects landscape IME and unsafe bottom inset`() {
        val cases = listOf(
            conversationSnapshot(width = 2_000, height = 1_000),
            conversationSnapshot(imeVisible = true),
            conversationSnapshot(systemBottomInset = 180),
        )
        for (unsafe in cases) {
            val adapter = FakeAdapter(snapshots = mutableListOf(unsafe))
            expectError(ErrorCode.E_BLOCKED) { macro(adapter).run() }
            assertEquals(0, adapter.probeCalls)
        }
    }

    @Test
    fun `OCR title without fictional icon labels permits one probe`() {
        val ocrConversation = snapshot(
            element(
                "o-title", "文件传输助手", source = "ocr", confidence = 0.91,
                centerX = 500, centerY = 100,
            ),
            revision = 31,
        )
        val adapter = FakeAdapter(
            snapshots = mutableListOf(ocrConversation),
            focusStates = stableFocus("fingerprint-ocr"),
        )

        val result = macro(adapter).run()

        assertTrue(result.ready)
        assertTrue(result.usedCoordinateFallback)
        assertEquals(1, adapter.probeCalls)
    }

    @Test
    fun `low-confidence OCR title blocks probe`() {
        val unsafe = snapshot(
            element(
                "o-title", "文件传输助手", source = "ocr", confidence = 0.64,
                centerX = 500, centerY = 100,
            ),
        )
        val adapter = FakeAdapter(snapshots = mutableListOf(unsafe))

        expectError(ErrorCode.E_BLOCKED) { macro(adapter).run() }
        assertEquals(0, adapter.probeCalls)
    }

    @Test
    fun `confirmation-like popup blocks coordinate fallback`() {
        val popup = conversationSnapshot(
            element("dialog-target", "发送给：文件传输助手", centerX = 500, centerY = 700),
            element("dialog-cancel", "取消", role = "button", centerX = 350, centerY = 1_250),
            element("dialog-confirm", "确定", role = "button", centerX = 650, centerY = 1_250),
        )
        val adapter = FakeAdapter(snapshots = mutableListOf(popup))

        expectError(ErrorCode.E_BLOCKED) { macro(adapter).run() }

        assertEquals(0, adapter.probeCalls)
    }

    @Test
    fun `revision change before probe is stale and does not tap`() {
        val adapter = FakeAdapter(
            snapshots = mutableListOf(
                conversationSnapshot(revision = 40),
                conversationSnapshot(revision = 41),
            ),
        )

        expectError(ErrorCode.E_STALE_REF) { macro(adapter).run() }

        assertEquals(0, adapter.probeCalls)
    }

    @Test
    fun `title identity change before probe is stale and does not tap`() {
        val changed = snapshot(
            element(
                "o-title", "其他会话", source = "ocr", confidence = 0.92,
                centerX = 500, centerY = 100,
            ),
            revision = 50,
        )
        val adapter = FakeAdapter(
            snapshots = mutableListOf(conversationSnapshot(revision = 50), changed),
        )

        expectError(ErrorCode.E_STALE_REF) { macro(adapter).run() }

        assertEquals(0, adapter.probeCalls)
    }

    @Test
    fun `popup appearing during probe revalidation is stale`() {
        val popup = conversationSnapshot(
            element("dialog", "确认发送", role = "button", centerX = 500, centerY = 1_000),
            revision = 60,
        )
        val adapter = FakeAdapter(
            snapshots = mutableListOf(conversationSnapshot(revision = 60), popup),
        )

        expectError(ErrorCode.E_STALE_REF) { macro(adapter).run() }

        assertEquals(0, adapter.probeCalls)
    }

    @Test
    fun `foreground changing after probe snapshot is stale before tap`() {
        val adapter = FakeAdapter(
            foregrounds = mutableListOf(
                P0MacroForeground(true, "com.tencent.mm"),
                P0MacroForeground(true, "com.tencent.mm"),
                P0MacroForeground(true, "com.android.launcher"),
            ),
            snapshots = mutableListOf(conversationSnapshot()),
        )

        expectError(ErrorCode.E_STALE_REF) { macro(adapter).run() }

        assertEquals(0, adapter.probeCalls)
    }

    @Test
    fun `already focused verified session needs neither ref nor coordinate probe`() {
        val noBottomSemantics = snapshot(
            element("conversation-title", "文件传输助手", centerX = 500, centerY = 100),
        )
        val adapter = FakeAdapter(
            snapshots = mutableListOf(noBottomSemantics),
            focusStates = mutableListOf(
                P0MacroFocus(true, true, true, "fingerprint-a", editable = true, stage = P0ElementStage.BOTTOM_INPUT),
                P0MacroFocus(true, true, true, "fingerprint-a", editable = true, stage = P0ElementStage.BOTTOM_INPUT),
            ),
        )

        val result = macro(adapter).run()

        assertTrue(result.ready)
        assertEquals(emptyList<String>(), adapter.clicks)
        assertEquals(0, adapter.probeCalls)
    }

    @Test
    fun `text inside proposed blank input region blocks coordinate fallback`() {
        val unsafe = conversationSnapshot(
            element(
                "input-text", "尚未清空", source = "ocr", confidence = 0.88,
                centerX = 500, centerY = 1_780,
            ),
        )
        val adapter = FakeAdapter(snapshots = mutableListOf(unsafe))

        expectError(ErrorCode.E_BLOCKED) { macro(adapter).run() }

        assertEquals(0, adapter.probeCalls)
    }

    @Test
    fun `action proof rejects a reused vision generation`() {
        val first = conversationSnapshot(visionGeneration = 7)
        val expected = P0FocusProbeValidator.build(first, emptyList())
            ?: throw AssertionError("expected valid proof")

        expectError(ErrorCode.E_STALE_REF) {
            P0FocusProbeValidator.revalidateForAction(
                expected = expected,
                fresh = first,
                foreground = P0MacroForeground(true, P0_WECHAT_PACKAGE),
                sensitiveSurfaceWords = emptyList(),
            )
        }
    }

    @Test
    fun `action proof accepts a newer title-only vision and rejects overlay`() {
        val expected = P0FocusProbeValidator.build(
            conversationSnapshot(visionGeneration = 7),
            emptyList(),
        ) ?: throw AssertionError("expected valid proof")
        val newer = conversationSnapshot(visionGeneration = 8)

        val validated = P0FocusProbeValidator.revalidateForAction(
            expected = expected,
            fresh = newer,
            foreground = P0MacroForeground(true, P0_WECHAT_PACKAGE),
            sensitiveSurfaceWords = emptyList(),
        )

        assertEquals(8L, validated.proof.visionGeneration)
        expectError(ErrorCode.E_STALE_REF) {
            P0FocusProbeValidator.revalidateForAction(
                expected = validated,
                fresh = newer.copy(visionGeneration = 9, blockingOverlay = true),
                foreground = P0MacroForeground(true, P0_WECHAT_PACKAGE),
                sensitiveSurfaceWords = emptyList(),
            )
        }
    }

    @Test
    fun `fresh proofs reject capture revision mismatch`() {
        val expectedFocus = P0FocusProbeValidator.build(
            conversationSnapshot(visionGeneration = 7),
            emptyList(),
        ) ?: throw AssertionError("expected valid proof")
        expectError(ErrorCode.E_STALE_REF) {
            P0FocusProbeValidator.revalidateForAction(
                expected = expectedFocus,
                fresh = conversationSnapshot(visionGeneration = 8).copy(captureRevision = 99),
                foreground = P0MacroForeground(true, P0_WECHAT_PACKAGE),
                sensitiveSurfaceWords = emptyList(),
            )
        }

        val initialStage = snapshot(
            element("search-input", "搜索", role = "input", centerX = 500, centerY = 110),
            revision = 4,
            visionGeneration = 7,
        )
        val expectedStage = P0StageRefActionValidator.build(P0RefStage.SEARCH_ENTRY, initialStage)
        expectError(ErrorCode.E_STALE_REF) {
            P0StageRefActionValidator.revalidate(
                expected = expectedStage,
                fresh = initialStage.copy(visionGeneration = 8, captureRevision = 99),
                foreground = P0MacroForeground(true, P0_WECHAT_PACKAGE),
                sensitiveSurfaceWords = emptyList(),
            )
        }
    }

    @Test
    fun `send control is never treated as an input or coordinate anchor`() {
        val conversation = conversationSnapshot(
            element("send", "发送消息", role = "button", centerX = 850, centerY = 1_800),
        )
        val adapter = FakeAdapter(snapshots = mutableListOf(conversation))

        expectError(ErrorCode.E_BLOCKED) { macro(adapter).run() }

        assertEquals(emptyList<String>(), adapter.clicks)
        assertEquals(0, adapter.probeCalls)
    }

    @Test
    fun `coordinate probe failure is not retried`() {
        val adapter = FakeAdapter(
            snapshots = mutableListOf(conversationSnapshot()),
            probeResult = false,
        )

        expectError(ErrorCode.E_VERIFY_FAIL) { macro(adapter).run() }

        assertEquals(1, adapter.probeCalls)
    }

    @Test
    fun `invalid screen geometry blocks coordinate probe`() {
        val adapter = FakeAdapter(
            snapshots = mutableListOf(conversationSnapshot(width = 0, height = 0)),
        )

        expectError(ErrorCode.E_BLOCKED) { macro(adapter).run() }

        assertEquals(0, adapter.probeCalls)
    }

    @Test
    fun `times out when focused node never appears after one probe`() {
        val adapter = FakeAdapter(
            snapshots = mutableListOf(conversationSnapshot()),
            focusStates = mutableListOf(P0MacroFocus(false, true, true, "fingerprint-a")),
        )

        val error = expectError(ErrorCode.E_TIMEOUT) { macro(adapter).run() }

        assertTrue(error.message.orEmpty().contains("输入框焦点"))
        assertEquals(1, adapter.probeCalls)
    }

    @Test
    fun `fails when IME is inactive`() {
        val adapter = FakeAdapter(
            snapshots = mutableListOf(conversationSnapshot()),
            focusStates = mutableListOf(P0MacroFocus(true, false, true, "fingerprint-a", editable = true, stage = P0ElementStage.BOTTOM_INPUT)),
        )

        val error = expectError(ErrorCode.E_TIMEOUT) { macro(adapter).run() }

        assertTrue(error.message.orEmpty().contains("IME"))
    }

    @Test
    fun `fails when InputConnection is unavailable`() {
        val adapter = FakeAdapter(
            snapshots = mutableListOf(conversationSnapshot()),
            focusStates = mutableListOf(P0MacroFocus(true, true, false, "fingerprint-a", editable = true, stage = P0ElementStage.BOTTOM_INPUT)),
        )

        val error = expectError(ErrorCode.E_TIMEOUT) { macro(adapter).run() }

        assertTrue(error.message.orEmpty().contains("InputConnection"))
    }

    @Test
    fun `focused non-editable node never qualifies as input readiness`() {
        val adapter = FakeAdapter(
            snapshots = mutableListOf(conversationSnapshot()),
            focusStates = mutableListOf(
                P0MacroFocus(
                    nodePresent = true,
                    imeActive = true,
                    inputConnectionAvailable = true,
                    fingerprint = "fingerprint-a",
                    focused = true,
                    editable = false,
                )
            ),
        )

        val error = expectError(ErrorCode.E_TIMEOUT) { macro(adapter).run() }

        assertTrue(error.message.orEmpty().contains("editable"))
    }

    @Test
    fun `focus readiness defaults fail closed unless editable was observed`() {
        val focus = P0MacroFocus(
            nodePresent = true,
            imeActive = true,
            inputConnectionAvailable = true,
            fingerprint = "fingerprint-a",
        )

        assertFalse(focus.ready)
    }

    @Test
    fun `blank fingerprint never qualifies as ready`() {
        val adapter = FakeAdapter(
            snapshots = mutableListOf(conversationSnapshot()),
            focusStates = mutableListOf(P0MacroFocus(true, true, true, "", editable = true, stage = P0ElementStage.BOTTOM_INPUT)),
        )

        expectError(ErrorCode.E_TIMEOUT) { macro(adapter).run() }
    }

    @Test
    fun `changed focused fingerprint fails closed`() {
        val adapter = FakeAdapter(
            snapshots = mutableListOf(conversationSnapshot()),
            focusStates = mutableListOf(
                P0MacroFocus(true, true, true, "fingerprint-a", editable = true, stage = P0ElementStage.BOTTOM_INPUT),
                P0MacroFocus(true, true, true, "fingerprint-b", editable = true, stage = P0ElementStage.BOTTOM_INPUT),
            ),
        )

        val error = expectError(ErrorCode.E_STALE_REF) { macro(adapter).run() }

        assertTrue(error.message.orEmpty().contains("fingerprint"))
    }

    @Test
    fun `final conversation identity change fails closed`() {
        val conversation = conversationSnapshot(
            element("input", "", role = "input", centerX = 500, centerY = 1_750),
        )
        val adapter = FakeAdapter(
            snapshots = mutableListOf(conversation, chatListWithSearch()),
            focusStates = stableFocus("fingerprint-a"),
        )

        val error = expectError(ErrorCode.E_STALE_REF) { macro(adapter).run() }

        assertTrue(error.message.orEmpty().contains("会话身份"))
    }

    @Test
    fun `final fresh vision rejects a newly sensitive surface`() {
        val conversation = conversationSnapshot(
            element("input", "", role = "input", centerX = 500, centerY = 1_750),
        )
        val sensitive = conversationSnapshot(
            element("danger", "请输入支付密码", centerX = 500, centerY = 900),
        )
        val adapter = FakeAdapter(
            snapshots = mutableListOf(conversation, sensitive),
            focusStates = mutableListOf(
                P0MacroFocus(true, true, true, "fingerprint-a", editable = true, stage = P0ElementStage.BOTTOM_INPUT),
                P0MacroFocus(true, true, true, "fingerprint-a", editable = true, stage = P0ElementStage.BOTTOM_INPUT),
                P0MacroFocus(true, true, true, "fingerprint-a", editable = true, stage = P0ElementStage.BOTTOM_INPUT),
            ),
        )

        expectError(ErrorCode.E_STALE_REF) { macro(adapter).run() }
    }

    @Test
    fun `final focus recheck rejects connection session change`() {
        val adapter = FakeAdapter(
            snapshots = mutableListOf(conversationSnapshot()),
            focusStates = mutableListOf(
                P0MacroFocus(true, true, true, "fingerprint-a", editable = true, stage = P0ElementStage.BOTTOM_INPUT),
                P0MacroFocus(true, true, true, "fingerprint-a", editable = true, stage = P0ElementStage.BOTTOM_INPUT),
                P0MacroFocus(true, true, true, "fingerprint-b", editable = true, stage = P0ElementStage.BOTTOM_INPUT),
            ),
        )

        val error = expectError(ErrorCode.E_STALE_REF) { macro(adapter).run() }

        assertTrue(error.message.orEmpty().contains("最终复核"))
    }

    @Test
    fun `foreground loss during polling fails immediately`() {
        val adapter = FakeAdapter(
            foregrounds = mutableListOf(
                P0MacroForeground(true, "com.tencent.mm"),
                P0MacroForeground(true, "com.android.launcher"),
            ),
            snapshots = mutableListOf(chatListWithSearch()),
        )

        expectError(ErrorCode.E_STALE_REF) { macro(adapter).run() }
    }

    @Test
    fun `sensitive WeChat page blocks before navigation`() {
        val sensitive = snapshot(
            element("title", "微信", centerX = 500, centerY = 90),
            element("search", "搜索", centerX = 500, centerY = 260),
            element("danger", "请输入支付密码完成转账", centerX = 500, centerY = 800),
        )
        val adapter = FakeAdapter(snapshots = mutableListOf(sensitive))

        val error = expectError(ErrorCode.E_BLOCKED) { macro(adapter).run() }

        assertTrue(error.message.orEmpty().contains("敏感"))
        assertEquals(emptyList<String>(), adapter.clicks)
    }

    @Test
    fun `injected safety vocabulary blocks before navigation`() {
        val sensitive = snapshot(
            element("title", "微信", centerX = 500, centerY = 90),
            element("search", "搜索", centerX = 500, centerY = 260),
            element("policy-danger", "需要短信验证码", centerX = 500, centerY = 800),
        )
        val adapter = FakeAdapter(snapshots = mutableListOf(sensitive))
        val configured = P0WeChatPrepareMacro(
            adapter = adapter,
            config = P0WeChatPrepareConfig(
                searchSurfaceTimeoutMs = 30,
                targetTimeoutMs = 30,
                conversationTimeoutMs = 30,
                focusTimeoutMs = 30,
                pollIntervalMs = 10,
                stableSamples = 2,
                sensitiveSurfaceWords = listOf("验证码"),
            ),
        )

        expectError(ErrorCode.E_BLOCKED) { configured.run() }

        assertEquals(emptyList<String>(), adapter.clicks)
    }

    @Test
    fun `unrecognized WeChat page blocks before navigation`() {
        val unknown = snapshot(element("title", "朋友圈", centerX = 500, centerY = 90))
        val adapter = FakeAdapter(snapshots = mutableListOf(unknown))

        val error = expectError(ErrorCode.E_BLOCKED) { macro(adapter).run() }

        assertTrue(error.message.orEmpty().contains("非敏感"))
        assertEquals(emptyList<String>(), adapter.clicks)
    }

    @Test
    fun `success reports runner-readable verified result`() {
        val search = snapshot(
            element("search-input", "", role = "input", centerX = 500, centerY = 110),
            element("cancel", "取消", centerX = 900, centerY = 110),
        )
        val target = snapshot(
            element("search-input", "", role = "input", centerX = 500, centerY = 110),
            element("target", "文件传输助手", centerX = 220, centerY = 520),
        )
        val conversation = conversationSnapshot(
            element("input", "", role = "input", centerX = 500, centerY = 1750),
        )
        val adapter = FakeAdapter(
            snapshots = mutableListOf(chatListWithSearch(), search, target, conversation),
            focusStates = stableFocus("fingerprint-a"),
        )

        val result = macro(adapter).run()

        assertTrue(result.ready)
        assertEquals("com.tencent.mm", result.packageName)
        assertEquals("文件传输助手", result.conversation)
        assertEquals("fingerprint-a", result.focusedInputFingerprint)
        assertEquals(2, result.stableSamples)
        assertEquals(listOf("search", "target", "input"), adapter.clicks)
        assertEquals(1, adapter.fixedQueryCalls)
        assertTrue(adapter.inputEvidenceClearCalls >= 2)
        assertEquals(0, adapter.textEntryCalls)
        assertEquals(0, adapter.enterCalls)
        val json = result.toJson()
        assertTrue(json.getBoolean("ready"))
        assertTrue(json.getBoolean("foreground_known"))
        assertTrue(json.getBoolean("input_connection_available"))
        assertTrue(json.getBoolean("input_editable"))
        assertEquals("p0_wechat_file_transfer_prepare", json.getString("name"))
        assertFalse(json.has("macro"))
        assertEquals("fingerprint-a", json.getString("focused_input_fingerprint"))
    }

    @Test
    fun `adapter capability surface cannot type press enter or confirm`() {
        val methods = P0WeChatPrepareAdapter::class.java.methods
        val fixedQuery = methods.single { it.name == "enterFixedFileTransferQuery" }
        val methodNames = methods.filterNot { it == fixedQuery }.map { it.name.lowercase() }

        assertFalse(methodNames.any { it.contains("type") || it.contains("text") })
        assertFalse(methodNames.any { it.contains("enter") || it.contains("key") })
        assertFalse(methodNames.any { it.contains("confirm") || it.contains("decision") })
        assertEquals(0, fixedQuery.parameterCount)
    }

    private fun macro(adapter: P0WeChatPrepareAdapter) = P0WeChatPrepareMacro(
        adapter = adapter,
        config = P0WeChatPrepareConfig(
            searchSurfaceTimeoutMs = 30,
            targetTimeoutMs = 30,
            conversationTimeoutMs = 30,
            focusTimeoutMs = 30,
            pollIntervalMs = 10,
            stableSamples = 2,
        ),
    )

    private fun stableFocus(id: String) = mutableListOf(
        P0MacroFocus(false, false, false, null),
        P0MacroFocus(true, true, true, id, editable = true, stage = P0ElementStage.BOTTOM_INPUT),
        P0MacroFocus(true, true, true, id, editable = true, stage = P0ElementStage.BOTTOM_INPUT),
    )

    private fun chatListWithSearch() = snapshot(
        element("title", "微信", centerX = 500, centerY = 90),
        element("search", "搜索", centerX = 500, centerY = 260),
    )

    private fun chatListWithTarget() = snapshot(
        element("title", "微信", centerX = 500, centerY = 90),
        element("search", "搜索", centerX = 500, centerY = 260),
        element("target", "文件传输助手", centerX = 220, centerY = 520),
    )

    private fun conversationSnapshot(
        vararg extra: P0MacroElement,
        width: Int = 1_000,
        height: Int = 2_000,
        revision: Long = 1,
        visionGeneration: Long = 0,
        imeVisible: Boolean = false,
        systemBottomInset: Int = 0,
    ) = snapshot(
        element(
            "o-title", "文件传输助手", source = "ocr", confidence = 0.91,
            centerX = width / 2, centerY = 100,
        ),
        *extra,
        width = width,
        height = height,
        revision = revision,
        visionGeneration = visionGeneration,
        imeVisible = imeVisible,
        systemBottomInset = systemBottomInset,
    )

    private fun snapshot(
        vararg elements: P0MacroElement,
        width: Int = 1_000,
        height: Int = 2_000,
        revision: Long = 1,
        visionGeneration: Long = 0,
        blockingOverlay: Boolean = false,
        imeVisible: Boolean = false,
        systemBottomInset: Int = 0,
    ) = P0MacroSnapshot(
        width, height, elements.toList(), revision,
        visionGeneration = visionGeneration,
        blockingOverlay = blockingOverlay,
        imeVisible = imeVisible,
        systemBottomInset = systemBottomInset,
    )

    private fun element(
        ref: String,
        text: String,
        role: String = "text",
        desc: String = "",
        source: String = "a11y",
        confidence: Double? = null,
        centerX: Int,
        centerY: Int,
    ) = P0MacroElement(
        ref = ref,
        role = role,
        text = text,
        description = desc,
        bounds = P0MacroRect(centerX - 50, centerY - 25, centerX + 50, centerY + 25),
        source = source,
        confidence = confidence,
        stage = when {
            (role == "input" && centerY < 600) || text in setOf("搜索", "取消") -> P0ElementStage.SEARCH
            centerY <= 240 -> P0ElementStage.TOOLBAR
            centerY >= 1_400 -> P0ElementStage.BOTTOM_INPUT
            else -> P0ElementStage.CONTENT
        },
    )

    private fun expectError(code: ErrorCode, block: () -> Unit): GatewayError {
        try {
            block()
            fail("expected $code")
        } catch (error: GatewayError) {
            assertEquals(code, error.code)
            return error
        }
        throw AssertionError("unreachable")
    }

    private class FakeAdapter(
        private val foregrounds: MutableList<P0MacroForeground> = mutableListOf(
            P0MacroForeground(true, "com.tencent.mm"),
        ),
        private val snapshots: MutableList<P0MacroSnapshot> = mutableListOf(),
        private val clickResults: MutableList<Boolean> = mutableListOf(),
        private val focusStates: MutableList<P0MacroFocus> = mutableListOf(),
        private val repeatedSnapshot: P0MacroSnapshot? = null,
        private val probeResult: Boolean = true,
    ) : P0WeChatPrepareAdapter {
        var snapshotCalls = 0
        var forceFreshCalls = 0
        var fixedQueryCalls = 0
        var inputEvidenceClearCalls = 0
        val clicks = mutableListOf<String>()
        var probeCalls = 0
        var lastProbe: P0FocusProbe? = null
        var textEntryCalls = 0
        var enterCalls = 0
        private var now = 0L
        private var lastSnapshot: P0MacroSnapshot? = null

        override fun foreground(): P0MacroForeground =
            if (foregrounds.size > 1) foregrounds.removeAt(0) else foregrounds.first()

        override fun snapshot(): P0MacroSnapshot {
            snapshotCalls++
            val next = if (snapshots.isNotEmpty()) snapshots.removeAt(0)
            else repeatedSnapshot ?: lastSnapshot ?: throw AssertionError("unexpected snapshot")
            lastSnapshot = next
            return next
        }

        override fun forceFreshVision(): P0MacroSnapshot {
            forceFreshCalls++
            val current = snapshot()
            return current.copy(visionGeneration = forceFreshCalls.toLong())
        }

        override fun enterFixedFileTransferQuery(): Boolean {
            fixedQueryCalls++
            inputEvidenceClearCalls += 2
            return true
        }

        override fun clickStage(action: P0StageRefAction): Boolean {
            clicks += when (action.stage) {
                P0RefStage.SEARCH_ENTRY -> "search"
                P0RefStage.TARGET_CONVERSATION -> "target"
                P0RefStage.INPUT_FIELD -> "input"
            }
            return if (clickResults.isNotEmpty()) clickResults.removeAt(0) else true
        }

        override fun probeFocus(probe: P0FocusProbe): Boolean {
            probeCalls++
            lastProbe = probe
            return probeResult
        }

        override fun focusedInput(): P0MacroFocus =
            if (focusStates.size > 1) focusStates.removeAt(0)
            else focusStates.firstOrNull() ?: P0MacroFocus(false, false, false, null)

        override fun monotonicMs(): Long = now

        override fun sleep(ms: Long) {
            now += ms
        }
    }
}
