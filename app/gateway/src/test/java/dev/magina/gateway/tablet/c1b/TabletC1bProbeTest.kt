package dev.magina.gateway.tablet.c1b

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.time.Instant

class TabletC1bProbeTest {
    @Test
    fun rootOnlyTreeKeepsRootHandleBindingAndSubtreeStatusSeparate() {
        val root = node(token = 101, windowId = 11)
        val frame = capture(listOf(window(11, root = root)))
        val observed = frame.windows.single()

        assertEquals(C1bRootHandleStatus.READABLE, observed.rootHandleStatus)
        assertEquals(C1bWindowBinding.EXACT, observed.rootWindowBinding)
        assertEquals(C1bSubtreeStatus.COMPLETE, observed.subtreeCapture.status)
        assertEquals(0, observed.subtreeCapture.rootChildCount)
        assertEquals(1, observed.subtreeCapture.visitedNodeCount)
        assertEquals(1, frame.nodes.size)
        assertTrue(frame.nodes.single().isRoot)
        assertEquals("aw1", observed.windowLabel)
        assertEquals("ap1", frame.panes.single().paneLabel)
        assertEquals("an1", frame.nodes.single().nodeLabel)
    }

    @Test
    fun degenerateRootIsRecordedAsOpaqueStructureWithoutSemanticPromotion() {
        val root = node(token = 102, windowId = 12, bounds = C1bRect(0, 0, 0, 0))
        val frame = capture(listOf(window(12, root = root)))
        val subtree = frame.windows.single().subtreeCapture
        val node = frame.nodes.single()

        assertEquals(C1bSubtreeStatus.COMPLETE, subtree.status)
        assertEquals(0, subtree.rootChildCount)
        assertEquals(1, subtree.visitedNodeCount)
        assertEquals(0, subtree.positiveVisibleGeometryNodeCount)
        assertEquals(C1bGeometryStatus.DEGENERATE, node.geometryStatus)
        assertEquals("unknown", node.toJson().getString("semantic_role"))
        assertFalse(frame.toJson().toString().contains("candidate"))
        assertFalse(frame.toJson().toString().contains("pane_role"))
    }

    @Test
    fun windowControlTypeKeepsRawPlatformCodeSeven() {
        val frame = capture(
            listOf(
                FakeWindow(
                    rawId = 70,
                    typeCode = 7,
                    root = null,
                    title = null,
                ),
                FakeWindow(rawId = 71, typeCode = 99, root = null, title = null),
            ),
        )

        assertEquals(7, frame.windows[0].platformTypeCode)
        assertEquals("window_control", frame.windows[0].type)
        assertEquals(99, frame.windows[1].platformTypeCode)
        assertEquals("unknown", frame.windows[1].type)
        assertTrue(frame.windows.all { it.subtreeCapture.status == C1bSubtreeStatus.NOT_ATTEMPTED })
    }

    @Test
    fun nativeWindowTitleOnlyPersistsQueryBoundMatchState() {
        val secretTitle = "机密会话标题-不应落盘"
        val queryHash = sha256(secretTitle)
        val root = node(token = 103, windowId = 13)
        val frame = capture(
            listOf(window(13, root = root, title = secretTitle)),
            expectedTitleHash = queryHash,
        )
        val json = frame.toJson().toString()

        assertEquals(C1bTitleMatchStatus.MATCH, frame.windows.single().expectedWindowTitleMatch)
        assertFalse(json.contains(secretTitle))
        assertFalse(json.contains(queryHash))
        assertFalse(frame.toString().contains("windowIdentityTokens"))
        assertFalse(frame.toString().contains("nodeIdentityTokens"))
        assertEquals(
            C1bTitleMatchStatus.OVER_BUDGET,
            c1bMatchWindowTitle("x".repeat(257), sha256("expected")),
        )
        assertEquals(C1bTitleMatchStatus.ABSENT, c1bMatchWindowTitle(null, sha256("expected")))
    }

    @Test
    fun realMetricsPreserveCurrentLandscapeEffectiveSize() {
        val display = c1bDisplayFromRealMetrics(0, 2_800, 1_968)

        assertEquals(2_800, display.width)
        assertEquals(1_968, display.height)
        assertEquals("landscape", display.orientation)
    }

    @Test
    fun residualInputFocusDoesNotBecomeAnEditor() {
        val root = node(token = 104, windowId = 14)
        val residual = node(
            token = 9_999,
            windowId = 14,
            bounds = C1bRect(0, 0, 0, 0),
            visible = false,
            enabled = false,
            editable = false,
            focused = false,
        )
        val port = FakePort(
            windowList = listOf(window(14, root = root, focused = true)),
            directFocus = residual,
        )
        val frame = probe(port).capture(request())

        assertEquals(C1bFocusStatus.WINDOW_ONLY, frame.focus.status)
        assertEquals("aw1", frame.focus.windowLabel)
        assertNull(frame.focus.nodeLabel)
        assertEquals(1, port.refreshCalls)
    }

    @Test
    fun exactFreshVisibleWechatEditorProducesEditorKnown() {
        val editor = node(
            token = 106,
            windowId = 15,
            bounds = C1bRect(100, 100, 500, 180),
            visible = true,
            enabled = true,
            editable = true,
            focused = true,
        )
        val root = node(token = 105, windowId = 15, children = listOf(editor))
        val port = FakePort(
            windowList = listOf(window(15, root = root, focused = true)),
            directFocus = editor,
        )
        val frame = probe(port).capture(request())

        assertEquals(C1bFocusStatus.EDITOR_KNOWN, frame.focus.status)
        assertEquals("aw1", frame.focus.windowLabel)
        assertEquals("an2", frame.focus.nodeLabel)
        assertEquals(1, frame.windows.single().subtreeCapture.focusedEditableNodeCount)
        assertEquals(1, port.refreshCalls)
    }

    @Test
    fun focusWindowBindingConflictNeverProducesEditorKnown() {
        val editor = node(token = 108, windowId = 88, editable = true, focused = true)
        val root = node(token = 107, windowId = 16, children = listOf(editor))
        val port = FakePort(
            windowList = listOf(window(16, root = root, focused = true)),
            directFocus = editor,
        )
        val frame = probe(port).capture(request())

        assertEquals(C1bFocusStatus.UNKNOWN, frame.focus.status)
        assertTrue(frame.nodes.any { it.windowIdBinding == C1bWindowBinding.MISMATCH })
        assertEquals(C1bSubtreeStatus.READ_ERROR, frame.windows.single().subtreeCapture.status)
    }

    @Test
    fun undefinedAndNegativeWindowIdsNeverBindOrStabilizeAcrossFrames() {
        listOf(-1, Int.MIN_VALUE).forEachIndexed { index, invalidId ->
            val healthyId = 200 + index
            val frame = capture(
                windows = listOf(
                    window(invalidId, node(2_000L + index, invalidId), bounds = LEFT),
                    window(healthyId, node(2_100L + index, healthyId), bounds = RIGHT),
                ),
            )

            assertTrue("id=$invalidId", frame.windowsTruncated)
            assertEquals("id=$invalidId", listOf(RIGHT), frame.windows.map { it.bounds })
            assertTrue("id=$invalidId", frame.windowIdentityTokens.values.all(::c1bIsDefinedWindowId))
            assertTrue("id=$invalidId", "window_id_invalid" in frame.diagnosticCodes)
        }

        val invalidRoot = capture(listOf(window(210, node(2_210, -1))))
        assertEquals(C1bWindowBinding.UNKNOWN, invalidRoot.windows.single().rootWindowBinding)
        assertTrue(invalidRoot.panes.isEmpty())
        assertTrue(invalidRoot.nodes.isEmpty())
        assertTrue("root_window_id_invalid" in invalidRoot.diagnosticCodes)

        fun invalidChildFrame(token: String, revision: Long, at: Instant): C1bRawFrame {
            val root = node(2_220, 220, children = listOf(node(2_221, -1)))
            return capture(
                windows = listOf(window(220, root)),
                revision = revision,
                captureToken = token,
                at = at,
            )
        }
        val invalidChildFirst = invalidChildFrame("c1", 220, FIRST_AT)
        val invalidChildSecond = invalidChildFrame("c2", 221, SECOND_AT)
        val invalidChildNode = invalidChildFirst.nodes.single {
            it.windowIdBinding == C1bWindowBinding.UNKNOWN
        }
        assertTrue("node_window_id_invalid" in invalidChildFirst.diagnosticCodes)
        assertFalse(invalidChildNode.nodeLabel in invalidChildFirst.nodeIdentityTokens)
        val invalidChildObservation = assembler().assemble(
            assemblyRequest(),
            listOf(invalidChildFirst, invalidChildSecond),
        )
        val firstInvalidNodeLabel = invalidChildObservation.frames[0].nodes
            .single { it.windowIdBinding == C1bWindowBinding.UNKNOWN }.nodeLabel
        val secondInvalidNodeLabel = invalidChildObservation.frames[1].nodes
            .single { it.windowIdBinding == C1bWindowBinding.UNKNOWN }.nodeLabel
        assertNotEquals(firstInvalidNodeLabel, secondInvalidNodeLabel)

        val stableSourceFirst = capture(
            listOf(window(230, node(2_230, 230), bounds = LEFT), window(231, node(2_231, 231), bounds = RIGHT)),
            revision = 230,
            captureToken = "c1",
            at = FIRST_AT,
        )
        val stableSourceSecond = capture(
            listOf(window(230, node(2_230, 230), bounds = LEFT), window(231, node(2_231, 231), bounds = RIGHT)),
            revision = 231,
            captureToken = "c2",
            at = SECOND_AT,
        )
        val forgedInvalidToken = assembler().assemble(
            assemblyRequest(),
            listOf(
                stableSourceFirst.copy(windowIdentityTokens = stableSourceFirst.windowIdentityTokens + ("aw1" to -1)),
                stableSourceSecond.copy(windowIdentityTokens = stableSourceSecond.windowIdentityTokens + ("aw1" to -1)),
            ),
        )
        val leftLabels = forgedInvalidToken.frames.map { frame ->
            frame.windows.single { it.bounds == LEFT }.windowLabel
        }
        assertNotEquals(leftLabels[0], leftLabels[1])
        assertTrue("window_identity_replacement" in forgedInvalidToken.consistency.reasonCodes)
    }

    @Test
    fun unreadableWindowDisplayIsDroppedInsteadOfBorrowingFrameDisplayTopology() {
        val failed = window(41, node(941, 41), bounds = LEFT)
        val healthy = window(42, node(942, 42), bounds = RIGHT)
        val frame = probe(
            FakePort(
                windowList = listOf(failed, healthy),
                throwingWindowDisplayIds = setOf(41),
            ),
        ).capture(request())

        assertTrue(frame.windowsTruncated)
        assertEquals(1, frame.windows.size)
        assertEquals(RIGHT, frame.windows.single().bounds)
        assertEquals(1, frame.panes.size)
        assertEquals(C1bFocusStatus.UNKNOWN, frame.focus.status)
        assertEquals("unknown", frame.ime.mode)
        assertEquals("unknown", frame.ime.binding)
        assertTrue("window_display_read_failed" in frame.diagnosticCodes)
        assertFalse(frame.toJson().toString().contains("window_display_read_failed"))
    }

    @Test
    fun criticalWindowShellReadFailuresAndInvalidValuesAreDroppedWithoutSentinelFallbacks() {
        val healthy = window(49, node(949, 49), bounds = RIGHT)
        val cases = listOf(
            "window_layer_read_failed" to FakePort(
                windowList = listOf(window(43, node(943, 43), bounds = LEFT), healthy),
                throwingWindowLayerIds = setOf(43),
            ),
            "window_layer_invalid" to FakePort(
                windowList = listOf(
                    FakeWindow(43, 1, layer = 40_000, bounds = LEFT, title = EXPECTED_TITLE, root = node(943, 43)),
                    healthy,
                ),
            ),
            "window_touchable_bounds_read_failed" to FakePort(
                windowList = listOf(window(43, node(943, 43), bounds = LEFT), healthy),
                throwingTouchableBoundsIds = setOf(43),
            ),
            "window_touchable_bounds_invalid" to FakePort(
                windowList = listOf(
                    FakeWindow(
                        43,
                        1,
                        bounds = LEFT,
                        touchableBounds = C1bRect(40_000, 0, 40_100, 100),
                        title = EXPECTED_TITLE,
                        root = node(943, 43),
                    ),
                    healthy,
                ),
            ),
            "window_active_read_failed" to FakePort(
                windowList = listOf(window(43, node(943, 43), bounds = LEFT), healthy),
                throwingWindowActiveIds = setOf(43),
            ),
            "window_focus_read_failed" to FakePort(
                windowList = listOf(window(43, node(943, 43), bounds = LEFT), healthy),
                throwingWindowFocusIds = setOf(43),
            ),
        )

        cases.forEach { (code, port) ->
            val frame = probe(port).capture(request())
            assertTrue("code=$code", frame.windowsTruncated)
            assertEquals("code=$code", 1, frame.windows.size)
            assertEquals("code=$code", RIGHT, frame.windows.single().bounds)
            assertEquals("code=$code", C1bFocusStatus.UNKNOWN, frame.focus.status)
            assertEquals("code=$code", "unknown", frame.ime.mode)
            assertEquals("code=$code", "unknown", frame.ime.binding)
            assertTrue("code=$code", code in frame.diagnosticCodes)
            assertFalse("code=$code", frame.toJson().toString().contains(code))
        }

        val legalNullTouchable = FakeWindow(
            rawId = 44,
            typeCode = 1,
            bounds = FULL,
            touchableBounds = null,
            title = EXPECTED_TITLE,
            root = node(944, 44),
        )
        val legalFrame = probe(FakePort(windowList = listOf(legalNullTouchable))).capture(request())
        assertFalse(legalFrame.windowsTruncated)
        assertNull(legalFrame.windows.single().touchableBounds)
    }

    @Test
    fun unreadablePlatformTypeCannotTurnPotentialImeIntoHiddenObservation() {
        fun failedTypeFrame(token: String, revision: Long, at: Instant): C1bRawFrame {
            val potentialIme = FakeWindow(
                rawId = 72,
                typeCode = 2,
                bounds = C1bRect(0, 1_500, 2_800, 1_968),
                title = null,
                root = null,
            )
            return probe(
                FakePort(
                    revision = revision,
                    windowList = listOf(
                        window(70, node(970, 70), bounds = LEFT),
                        window(71, node(971, 71), bounds = RIGHT),
                        potentialIme,
                    ),
                    throwingWindowTypeIds = setOf(72),
                ),
                at = at,
            ).capture(request(token))
        }

        val first = failedTypeFrame("c1", 70, FIRST_AT)
        val second = failedTypeFrame("c2", 71, SECOND_AT)
        val observation = assembler().assemble(assemblyRequest(), listOf(first, second))

        assertTrue(first.windowsTruncated)
        assertTrue(first.windows.none { it.type == "input_method" })
        assertFalse(first.ime.visible)
        assertEquals("unknown", first.ime.mode)
        assertEquals("unknown", first.ime.binding)
        assertTrue("window_type_read_failed" in first.diagnosticCodes)
        assertFalse(first.toJson().toString().contains("window_type_read_failed"))
        assertTrue("window_inventory_truncated" in observation.reasonCodes)
        assertTrue("ime_inventory_invalid" in observation.reasonCodes)
        assertTrue(observation.reasonCodes.all { it in CONTRACT_REASON_CODES })
    }

    @Test
    fun successfullyReadUnknownPlatformTypeIsRetainedButBlocksImeHiddenAndFocusClaims() {
        fun unknownTypeFrame(token: String, revision: Long, at: Instant): C1bRawFrame = capture(
            windows = listOf(
                window(73, node(973, 73), bounds = LEFT),
                window(74, node(974, 74), bounds = RIGHT),
                FakeWindow(rawId = 75, typeCode = 0, bounds = FULL, title = null, root = null),
            ),
            revision = revision,
            captureToken = token,
            at = at,
        )

        val first = unknownTypeFrame("c1", 73, FIRST_AT)
        val second = unknownTypeFrame("c2", 74, SECOND_AT)
        val result = assembler().assemble(assemblyRequest(), listOf(first, second))
        val unknown = first.windows.single { it.platformTypeCode == 0 }

        assertFalse(first.windowsTruncated)
        assertEquals("unknown", unknown.type)
        assertEquals(C1bFocusStatus.UNKNOWN, first.focus.status)
        assertFalse(first.ime.visible)
        assertEquals("unknown", first.ime.mode)
        assertEquals("unknown", first.ime.binding)
        assertTrue("window_type_invalid" in result.reasonCodes)
        assertTrue("ime_inventory_invalid" in result.reasonCodes)
        assertFalse("focus_inventory_invalid" in result.reasonCodes)
        assertTrue(result.reasonCodes.all { it in CONTRACT_REASON_CODES })
    }

    @Test
    fun assemblerNeverAcceptsHiddenImeFromTruncatedOrUnknownWindowTypeInventory() {
        fun hiddenIme(token: String) = C1bImeObservation(false, "none", null, "not_active", null, token)
        fun validFrame(token: String, revision: Long, at: Instant): C1bRawFrame = capture(
            windows = listOf(
                window(240, node(2_240, 240), bounds = LEFT),
                window(241, node(2_241, 241), bounds = RIGHT),
            ),
            revision = revision,
            captureToken = token,
            at = at,
        )
        val truncatedFrames = listOf(
            validFrame("c1", 240, FIRST_AT),
            validFrame("c2", 241, SECOND_AT),
        ).map { frame ->
            frame.copy(
                windowsTruncated = true,
                focus = C1bFocusObservation(C1bFocusStatus.UNKNOWN, null, null),
                ime = hiddenIme(frame.capture.token),
            )
        }
        val truncatedResult = assembler().assemble(assemblyRequest(), truncatedFrames)
        assertTrue("window_inventory_truncated" in truncatedResult.reasonCodes)
        assertTrue("ime_inventory_invalid" in truncatedResult.reasonCodes)

        fun unknownTypeFrame(token: String, revision: Long, at: Instant): C1bRawFrame = capture(
            windows = listOf(
                window(242, node(2_242, 242), bounds = LEFT),
                window(243, node(2_243, 243), bounds = RIGHT),
                FakeWindow(rawId = 244, typeCode = 0, bounds = FULL, title = null, root = null),
            ),
            revision = revision,
            captureToken = token,
            at = at,
        ).let { frame -> frame.copy(ime = hiddenIme(token)) }
        val unknownResult = assembler().assemble(
            assemblyRequest(),
            listOf(unknownTypeFrame("c1", 242, FIRST_AT), unknownTypeFrame("c2", 243, SECOND_AT)),
        )
        assertTrue("window_type_invalid" in unknownResult.reasonCodes)
        assertTrue("ime_inventory_invalid" in unknownResult.reasonCodes)
    }

    @Test
    fun assemblerIndependentlyRejectsImeCaptureTokenBoundToTheWrongFrame() {
        fun frame(token: String, revision: Long, at: Instant): C1bRawFrame = capture(
            windows = listOf(
                window(245, node(2_245, 245), bounds = LEFT),
                window(246, node(2_246, 246), bounds = RIGHT),
            ),
            revision = revision,
            captureToken = token,
            at = at,
        )
        val c1 = frame("c1", 245, FIRST_AT).let { raw ->
            raw.copy(ime = raw.ime.copy(captureToken = "c2"))
        }
        val c2 = frame("c2", 246, SECOND_AT)

        val result = assembler().assemble(assemblyRequest(), listOf(c1, c2))

        assertTrue("capture-token mismatch must be recomputed outside the drift signature", result.consistency.stable)
        assertTrue("ime_inventory_invalid" in result.reasonCodes)
    }

    @Test
    fun incompleteApplicationSubtreesCannotProduceAbsentOrWindowOnlyFocus() {
        val brokenRoot = node(980, 80, children = listOf(node(981, 80)))
        val readErrorFrame = probe(
            FakePort(
                windowList = listOf(window(80, brokenRoot, focused = true)),
                throwingChildren = setOf(980L to 0),
            ),
        ).capture(request())
        val notAttemptedFrame = probe(
            FakePort(windowList = listOf(window(81, root = null))),
        ).capture(request())
        val structuralRoot = node(982, 82)
        val structuralFailureFrame = probe(
            FakePort(
                windowList = listOf(window(82, structuralRoot)),
                throwingNodeFacts = mapOf(982L to setOf("window_id")),
            ),
        ).capture(request())

        assertEquals(C1bSubtreeStatus.READ_ERROR, readErrorFrame.windows.single().subtreeCapture.status)
        assertEquals(C1bSubtreeStatus.NOT_ATTEMPTED, notAttemptedFrame.windows.single().subtreeCapture.status)
        assertEquals(
            C1bWindowBinding.UNKNOWN,
            structuralFailureFrame.windows.single().rootWindowBinding,
        )
        listOf(readErrorFrame, notAttemptedFrame, structuralFailureFrame).forEach { frame ->
            assertEquals(C1bFocusStatus.UNKNOWN, frame.focus.status)
            assertNull(frame.focus.windowLabel)
            assertNull(frame.focus.nodeLabel)
            assertTrue("focus_inventory_invalid" in frame.diagnosticCodes)
        }
    }

    @Test
    fun assemblerExpectsUnknownFocusForEveryIncompleteApplicationTopologyShape() {
        val baseFirst = capture(
            listOf(window(83, node(983, 83), bounds = LEFT), window(84, node(984, 84), bounds = RIGHT)),
            revision = 83,
            captureToken = "c1",
            at = FIRST_AT,
        )
        val baseSecond = capture(
            listOf(window(83, node(983, 83), bounds = LEFT), window(84, node(984, 84), bounds = RIGHT)),
            revision = 84,
            captureToken = "c2",
            at = SECOND_AT,
        )
        val cases: List<Pair<String, (C1bWindowObservation) -> C1bWindowObservation>> = listOf(
            "status" to { window ->
                window.copy(subtreeCapture = window.subtreeCapture.copy(status = C1bSubtreeStatus.READ_ERROR))
            },
            "root_child" to { window ->
                window.copy(subtreeCapture = window.subtreeCapture.copy(rootChildCount = null))
            },
            "read_error" to { window ->
                window.copy(subtreeCapture = window.subtreeCapture.copy(readErrorCount = 1))
            },
            "budget" to { window ->
                window.copy(subtreeCapture = window.subtreeCapture.copy(budgetExhausted = true))
            },
            "root_handle" to { window -> window.copy(rootHandleStatus = C1bRootHandleStatus.UNREADABLE) },
            "binding" to { window -> window.copy(rootWindowBinding = C1bWindowBinding.UNKNOWN) },
            "owner" to { window -> window.copy(rootPackage = null) },
            "bounds" to { window -> window.copy(bounds = null) },
        )

        cases.forEach { (name, mutation) ->
            fun incomplete(frame: C1bRawFrame, focus: C1bFocusObservation): C1bRawFrame = frame.copy(
                windows = frame.windows.mapIndexed { index, window -> if (index == 0) mutation(window) else window },
                focus = focus,
            )
            val unknownFocus = C1bFocusObservation(C1bFocusStatus.UNKNOWN, null, null)
            val accepted = assembler().assemble(
                assemblyRequest(),
                listOf(incomplete(baseFirst, unknownFocus), incomplete(baseSecond, unknownFocus)),
            )
            assertFalse("case=$name", "focus_inventory_invalid" in accepted.reasonCodes)

            val spoofedAbsent = C1bFocusObservation(C1bFocusStatus.ABSENT, null, null)
            val rejected = assembler().assemble(
                assemblyRequest(),
                listOf(incomplete(baseFirst, spoofedAbsent), incomplete(baseSecond, spoofedAbsent)),
            )
            assertTrue("case=$name", "focus_inventory_invalid" in rejected.reasonCodes)
        }
    }

    @Test
    fun assemblerRejectsFocusClaimsWhenPersistedPaneNodeOrCountTopologyDrifts() {
        val baseFirst = capture(
            listOf(window(85, node(985, 85), bounds = LEFT), window(86, node(986, 86), bounds = RIGHT)),
            revision = 85,
            captureToken = "c1",
            at = FIRST_AT,
        )
        val baseSecond = capture(
            listOf(window(85, node(985, 85), bounds = LEFT), window(86, node(986, 86), bounds = RIGHT)),
            revision = 86,
            captureToken = "c2",
            at = SECOND_AT,
        )
        val mutations: List<Pair<String, (C1bRawFrame) -> C1bRawFrame>> = listOf(
            "pane_bounds" to { frame ->
                frame.copy(panes = frame.panes.mapIndexed { index, pane ->
                    if (index == 0) pane.copy(bounds = RIGHT) else pane
                })
            },
            "root_missing" to { frame ->
                frame.copy(nodes = frame.nodes.mapIndexed { index, node ->
                    if (index == 0) node.copy(isRoot = false) else node
                })
            },
            "visited_count" to { frame ->
                frame.copy(windows = frame.windows.mapIndexed { index, window ->
                    if (index == 0) {
                        window.copy(
                            subtreeCapture = window.subtreeCapture.copy(
                                visitedNodeCount = window.subtreeCapture.visitedNodeCount + 1,
                            ),
                        )
                    } else {
                        window
                    }
                })
            },
        )

        mutations.forEach { (name, mutate) ->
            fun withFocus(frame: C1bRawFrame, focus: C1bFocusObservation): C1bRawFrame =
                mutate(frame).copy(focus = focus)

            val unknown = C1bFocusObservation(C1bFocusStatus.UNKNOWN, null, null)
            val accepted = assembler().assemble(
                assemblyRequest(),
                listOf(withFocus(baseFirst, unknown), withFocus(baseSecond, unknown)),
            )
            assertFalse("case=$name", "focus_inventory_invalid" in accepted.reasonCodes)
            assertFalse(accepted.toJson().getBoolean("layout_accepted"))
            assertFalse(accepted.toJson().getBoolean("wechat_layout_verified"))
            assertFalse(accepted.toJson().getBoolean("editor_action_ready"))

            val absent = C1bFocusObservation(C1bFocusStatus.ABSENT, null, null)
            val rejected = assembler().assemble(
                assemblyRequest(),
                listOf(withFocus(baseFirst, absent), withFocus(baseSecond, absent)),
            )
            assertTrue("case=$name", "focus_inventory_invalid" in rejected.reasonCodes)
        }
    }

    @Test
    fun rootWindowIdMismatchHasNoProjectionAndProducesOnlyClosedHighLevelReasons() {
        val first = capture(
            listOf(
                window(33, root = node(190, 999), bounds = LEFT),
                window(34, root = node(191, 34), bounds = RIGHT),
            ),
            revision = 50,
            captureToken = "c1",
            at = FIRST_AT,
        )
        val second = capture(
            listOf(
                window(33, root = node(190, 999), bounds = LEFT),
                window(34, root = node(191, 34), bounds = RIGHT),
            ),
            revision = 51,
            captureToken = "c2",
            at = SECOND_AT,
        )
        val mismatchWindow = first.windows.single { it.windowLabel == "aw1" }
        val result = assembler().assemble(assemblyRequest(), listOf(first, second))

        assertEquals(C1bWindowBinding.MISMATCH, mismatchWindow.rootWindowBinding)
        assertEquals(C1bSubtreeStatus.READ_ERROR, mismatchWindow.subtreeCapture.status)
        assertTrue(first.panes.none { it.windowLabel == "aw1" })
        assertTrue(first.nodes.none { it.windowLabel == "aw1" })
        assertTrue("root_window_binding_invalid" in result.reasonCodes)
        assertTrue("window_root_projection_invalid" in result.reasonCodes)
        assertTrue(result.reasonCodes.all { it in CONTRACT_REASON_CODES })
    }

    @Test
    fun twoEligibleFocusedEditorsAreConflictAndDirectFocusIsReadExactlyOnce() {
        val editorOne = node(201, 35, bounds = C1bRect(100, 100, 400, 180), editable = true, focused = true)
        val editorTwo = node(202, 36, bounds = C1bRect(1_000, 100, 1_400, 180), editable = true, focused = true)
        val port = FakePort(
            windowList = listOf(
                window(35, node(203, 35, children = listOf(editorOne)), bounds = LEFT, focused = true),
                window(36, node(204, 36, children = listOf(editorTwo)), bounds = RIGHT, focused = true),
            ),
            directFocus = editorOne,
        )
        val frame = probe(port).capture(request())

        assertEquals(C1bFocusStatus.CONFLICT, frame.focus.status)
        assertNull(frame.focus.windowLabel)
        assertNull(frame.focus.nodeLabel)
        assertEquals(1, port.inputFocusCalls)
    }

    @Test
    fun collidingLegacyHashBucketsNeverAliasDistinctNodesOrDirectFocus() {
        val first = node(777, 37, bounds = C1bRect(100, 100, 400, 180), editable = true, focused = true)
        val collision = node(777, 37, bounds = C1bRect(500, 100, 800, 180), editable = true, focused = true)
        val directCollision = node(777, 37, bounds = requireNotNull(first.bounds), editable = true, focused = true)
        val root = node(778, 37, children = listOf(first, collision))
        val frame = probe(
            FakePort(
                windowList = listOf(window(37, root = root, focused = true)),
                directFocus = directCollision,
            ),
        ).capture(request())

        assertEquals(3, frame.nodes.size)
        assertEquals(2, frame.windows.single().subtreeCapture.focusedEditableNodeCount)
        assertEquals(C1bFocusStatus.CONFLICT, frame.focus.status)
        assertFalse("node_duplicate_detected" in frame.diagnosticCodes)
    }

    @Test
    fun focusRelevantReadFailuresCanNeverDowngradeToAbsentOrWindowOnly() {
        val fields = listOf("window_id", "bounds", "visible", "enabled", "editable", "focused", "package")
        fields.forEachIndexed { index, field ->
            val editor = node(
                token = 800L + index,
                windowId = 38,
                bounds = C1bRect(100, 100, 400, 180),
                editable = true,
                focused = true,
            )
            val frame = probe(
                FakePort(
                    windowList = listOf(window(38, node(799, 38, children = listOf(editor)), focused = true)),
                    throwingNodeFacts = mapOf(editor.token to setOf(field)),
                ),
            ).capture(request())

            assertEquals("field=$field", C1bFocusStatus.UNKNOWN, frame.focus.status)
            assertTrue("field=$field", "focus_inventory_invalid" in frame.diagnosticCodes)
        }

        val windowFocusFrame = probe(
            FakePort(
                windowList = listOf(window(39, node(900, 39), focused = true)),
                throwingWindowFocusIds = setOf(39),
            ),
        ).capture(request())
        assertEquals(C1bFocusStatus.UNKNOWN, windowFocusFrame.focus.status)
        assertTrue(windowFocusFrame.windowsTruncated)
        assertTrue(windowFocusFrame.windows.isEmpty())
        assertEquals("unknown", windowFocusFrame.ime.mode)
        assertTrue("window_focus_read_failed" in windowFocusFrame.diagnosticCodes)
    }

    @Test
    fun schemaBoundariesRejectSquareAndOutOfRangeWindowFactsAndSaturateReadErrors() {
        expectFailure { C1bDisplayRead(0, 1_000, 1_000) }
        val validSubtree = C1bSubtreeObservation(
            C1bSubtreeStatus.COMPLETE,
            0,
            1,
            1,
            0,
            0,
            false,
        )
        fun boundaryWindow(displayId: Int, platformTypeCode: Int) = C1bWindowObservation(
            "aw1",
            displayId,
            platformTypeCode,
            "application",
            C1bRootHandleStatus.READABLE,
            C1B_WECHAT_PACKAGE,
            C1bWindowBinding.EXACT,
            validSubtree,
            C1bTitleMatchStatus.NO_MATCH,
            1,
            FULL,
            FULL,
            false,
            false,
        )
        expectFailure { boundaryWindow(17, 1) }
        expectFailure { boundaryWindow(0, 256) }
        expectFailure {
            C1bSubtreeObservation(C1bSubtreeStatus.READ_ERROR, null, 0, 0, 0, 513, false)
        }

        val factNames = setOf("window_id", "bounds", "visible", "enabled", "editable", "focused", "package")
        val leaves = (1L..100L).map { token -> node(1_000L + token, 40) }
        val frame = probe(
            FakePort(
                windowList = listOf(window(40, node(999, 40, children = leaves))),
                throwingNodeFacts = leaves.associate { leaf -> leaf.token to factNames },
            ),
        ).capture(request())
        val subtree = frame.windows.single().subtreeCapture
        assertEquals(512, subtree.readErrorCount)
        assertEquals(512, subtree.toJson().getInt("read_error_count"))
    }

    @Test
    fun staleOrGeometryDriftingDirectFocusIsAConflictNotWindowOnly() {
        val observedEditor = node(token = 109, windowId = 30, editable = true, focused = true)
        val root = node(token = 1080, windowId = 30, children = listOf(observedEditor))
        val stale = node(
            token = 109,
            windowId = 30,
            bounds = C1bRect(10, 10, 100, 80),
            editable = true,
            focused = true,
            refreshResult = false,
        )
        val staleFrame = probe(
            FakePort(windowList = listOf(window(30, root = root, focused = true)), directFocus = stale),
        ).capture(request())
        assertEquals(C1bFocusStatus.CONFLICT, staleFrame.focus.status)

        val shifted = node(
            token = 109,
            windowId = 30,
            bounds = C1bRect(20, 20, 200, 100),
            editable = true,
            focused = true,
        )
        val shiftedFrame = probe(
            FakePort(windowList = listOf(window(30, root = root, focused = true)), directFocus = shifted),
        ).capture(request())
        assertEquals(C1bFocusStatus.CONFLICT, shiftedFrame.focus.status)
    }

    @Test
    fun globalBudgetUsesFairRoundRobinAcrossWindows() {
        val deepLeaf = node(token = 112, windowId = 17)
        val deepChild = node(token = 111, windowId = 17, children = listOf(deepLeaf))
        val firstRoot = node(token = 110, windowId = 17, children = listOf(deepChild))
        val secondRoot = node(token = 120, windowId = 18)
        val frame = capture(
            listOf(window(17, root = firstRoot), window(18, root = secondRoot)),
            limits = C1bProbeLimits(maximumNodesPerWindow = 10, maximumTotalNodes = 2),
        )

        assertEquals(listOf("aw1", "aw2"), frame.nodes.map { it.windowLabel })
        assertEquals(1, frame.windows[0].subtreeCapture.visitedNodeCount)
        assertEquals(1, frame.windows[1].subtreeCapture.visitedNodeCount)
        assertEquals(C1bSubtreeStatus.TRUNCATED, frame.windows[0].subtreeCapture.status)
        assertEquals(C1bSubtreeStatus.COMPLETE, frame.windows[1].subtreeCapture.status)
        assertTrue(frame.nodesTruncated)
    }

    @Test
    fun childErrorsCyclesAndDuplicatesAreBoundedPerWindow() {
        val duplicate = node(token = 131, windowId = 19)
        val cyclicRoot = node(token = 130, windowId = 19)
        cyclicRoot.children += cyclicRoot
        cyclicRoot.children += duplicate
        cyclicRoot.children += duplicate
        cyclicRoot.children += node(token = 132, windowId = 19)
        val healthyRoot = node(token = 140, windowId = 20)
        val port = FakePort(
            windowList = listOf(window(19, root = cyclicRoot), window(20, root = healthyRoot)),
            throwingChildren = setOf(130L to 3),
        )
        val frame = probe(port).capture(request())
        val failed = frame.windows[0].subtreeCapture
        val healthy = frame.windows[1].subtreeCapture

        assertEquals(C1bSubtreeStatus.READ_ERROR, failed.status)
        assertEquals(4, failed.rootChildCount)
        assertTrue(failed.readErrorCount >= 3)
        assertEquals(C1bSubtreeStatus.COMPLETE, healthy.status)
        assertEquals(1, healthy.visitedNodeCount)
        assertTrue("node_cycle_detected" in frame.diagnosticCodes)
        assertTrue("node_duplicate_detected" in frame.diagnosticCodes)
        assertTrue("child_read_failed" in frame.diagnosticCodes)
    }

    @Test
    fun listReorderingKeepsStableLabelsAndDoesNotCreateFalseDrift() {
        val first = capture(
            listOf(
                window(21, root = node(151, 21), bounds = LEFT),
                window(22, root = node(152, 22), bounds = RIGHT),
            ),
            revision = 10,
            captureToken = "c1",
            at = FIRST_AT,
        )
        val second = capture(
            listOf(
                window(22, root = node(152, 22), bounds = RIGHT),
                window(21, root = node(151, 21), bounds = LEFT),
            ),
            revision = 11,
            captureToken = "c2",
            at = SECOND_AT,
        )
        val observation = assembler().assemble(assemblyRequest(), listOf(first, second))

        assertTrue(observation.consistency.stable)
        assertFalse("capture_semantics_drift" in observation.consistency.reasonCodes)
        val firstLabels = observation.frames[0].windows.associate { it.bounds to it.windowLabel }
        val secondLabels = observation.frames[1].windows.associate { it.bounds to it.windowLabel }
        assertEquals(firstLabels, secondLabels)
    }

    @Test
    fun mirroredGeometryChangesFactsButNeverInfersLeftOrRightRoles() {
        val first = capture(
            listOf(
                window(23, root = node(161, 23), bounds = LEFT),
                window(24, root = node(162, 24), bounds = RIGHT),
            ),
            revision = 20,
            captureToken = "c1",
            at = FIRST_AT,
        )
        val mirrored = capture(
            listOf(
                window(23, root = node(161, 23), bounds = RIGHT),
                window(24, root = node(162, 24), bounds = LEFT),
            ),
            revision = 21,
            captureToken = "c2",
            at = SECOND_AT,
        )
        val observation = assembler().assemble(assemblyRequest(), listOf(first, mirrored))
        val rawJson = observation.frames.joinToString { it.toJson().toString() }

        assertFalse(observation.consistency.stable)
        assertTrue("capture_semantics_drift" in observation.consistency.reasonCodes)
        assertTrue(observation.frames.flatMap { it.panes }.all {
            it.toJson().getString("semantic_role") == "unknown" &&
                it.toJson().getJSONArray("semantic_evidence").length() == 0
        })
        assertTrue(observation.frames.flatMap { it.nodes }.all {
            it.toJson().getString("semantic_role") == "unknown"
        })
        assertFalse(rawJson.contains("left_pane"))
        assertFalse(rawJson.contains("right_pane"))
        assertFalse(rawJson.contains("candidatePaneRole"))
    }

    @Test
    fun assemblerEmitsExactClosedTopLevelAndPermanentSafetyClaims() {
        val frames = listOf(
            capture(
                listOf(window(25, node(171, 25), bounds = LEFT), window(26, node(172, 26), bounds = RIGHT)),
                revision = 30,
                captureToken = "c1",
                at = FIRST_AT,
            ),
            capture(
                listOf(window(25, node(171, 25), bounds = LEFT), window(26, node(172, 26), bounds = RIGHT)),
                revision = 31,
                captureToken = "c2",
                at = SECOND_AT,
            ),
        )
        val json = assembler().assemble(assemblyRequest(), frames).toJson()

        assertEquals(
            setOf(
                "schema", "run_id", "captured_at", "mode", "expected_title_hash", "provenance",
                "upstream_t0", "route", "privacy", "frames", "consistency", "diagnostic_status",
                "reason_codes", "layout_accepted", "wechat_layout_verified", "editor_action_ready",
                "p0_capability", "p0_blockers", "execution_grant",
            ),
            json.keySet(),
        )
        assertEquals(TABLET_C1B_SCHEMA, json.getString("schema"))
        assertEquals(2, json.getJSONArray("frames").length())
        assertFalse(json.getBoolean("layout_accepted"))
        assertFalse(json.getBoolean("wechat_layout_verified"))
        assertFalse(json.getBoolean("editor_action_ready"))
        assertEquals("unsupported", json.getString("p0_capability"))
        assertFalse(json.getBoolean("execution_grant"))
        assertFalse(json.getJSONObject("route").getBoolean("device_action_allowed"))
        assertFalse(json.getJSONObject("route").getBoolean("settings_mutation_allowed"))
        assertFalse(json.getJSONObject("route").getBoolean("screenshot_allowed"))
        assertFalse(json.getJSONObject("route").getBoolean("ocr_allowed"))
        assertTrue(json.getJSONObject("upstream_t0").getJSONArray("readiness_reasons").length() >= 1)
        assertFalse(json.toString().contains("rawWindowId"))
        assertFalse(json.toString().contains("nodeIdentityTokens"))
        val frame = json.getJSONArray("frames").getJSONObject(0)
        assertEquals(
            setOf(
                "capture_id", "captured_at", "capture", "display", "a11y_windows", "windows_truncated",
                "panes", "panes_truncated", "node_observations", "nodes_truncated", "focus", "ime",
            ),
            frame.keySet(),
        )
        assertEquals(
            setOf(
                "window_label", "identity_namespace", "display_id", "platform_type_code", "type",
                "root_handle_status", "root_package", "root_window_binding", "subtree_capture",
                "expected_window_title_match", "layer", "bounds", "touchable_bounds", "active", "focused",
            ),
            frame.getJSONArray("a11y_windows").getJSONObject(0).keySet(),
        )
        assertEquals(
            setOf(
                "node_label", "window_label", "pane_label", "source", "is_root", "window_id_binding",
                "semantic_role", "geometry_status", "bounds", "visible", "enabled", "editable",
                "scrollable", "focused",
            ),
            frame.getJSONArray("node_observations").getJSONObject(0).keySet(),
        )
        assertTrue(allJsonKeys(json).none { "target" in it })
    }

    @Test
    fun rawAndAssembledStringFormsNeverExposeTitlesOrRawIdentityTokens() {
        val secret = "SECRET_TITLE_DO_NOT_PERSIST_20260826"
        val secretHash = sha256(secret)
        val first = capture(
            listOf(
                window(987_654_321, node(Long.MAX_VALUE - 10, 987_654_321), LEFT, secret),
                window(876_543_210, node(Long.MAX_VALUE - 20, 876_543_210), RIGHT, secret),
            ),
            expectedTitleHash = secretHash,
            revision = 60,
            captureToken = "c1",
            at = FIRST_AT,
        )
        val second = capture(
            listOf(
                window(987_654_321, node(Long.MAX_VALUE - 10, 987_654_321), LEFT, secret),
                window(876_543_210, node(Long.MAX_VALUE - 20, 876_543_210), RIGHT, secret),
            ),
            expectedTitleHash = secretHash,
            revision = 61,
            captureToken = "c2",
            at = SECOND_AT,
        )
        val observation = assembler().assemble(assemblyRequest(secretHash), listOf(first, second))
        val persistedForms = listOf(first.toJson().toString(), first.toString(), observation.toJson().toString(), observation.toString())

        persistedForms.forEach { persisted ->
            assertFalse(persisted.contains(secret))
            assertFalse(persisted.contains("987654321"))
            assertFalse(persisted.contains("876543210"))
            assertFalse(persisted.contains((Long.MAX_VALUE - 10).toString()))
            assertFalse(persisted.contains((Long.MAX_VALUE - 20).toString()))
        }
        assertTrue(observation.frames.flatMap { it.windows }
            .all { it.expectedWindowTitleMatch == C1bTitleMatchStatus.MATCH })
        assertTrue(allJsonKeys(observation.toJson()).none { "target" in it })
    }

    @Test
    fun lowLevelReadDiagnosticsNeverEscapeIntoClosedTopLevelReasonCodes() {
        val brokenRootOne = node(181, 31)
        brokenRootOne.children += brokenRootOne
        val brokenRootTwo = node(181, 31)
        brokenRootTwo.children += brokenRootTwo
        val first = capture(
            listOf(window(31, brokenRootOne), window(32, node(182, 32))),
            revision = 40,
            captureToken = "c1",
            at = FIRST_AT,
        )
        val second = capture(
            listOf(window(31, brokenRootTwo), window(32, node(182, 32))),
            revision = 41,
            captureToken = "c2",
            at = SECOND_AT,
        )
        val result = assembler().assemble(assemblyRequest(), listOf(first, second))

        assertTrue("subtree_capture_incomplete" in result.reasonCodes)
        assertTrue(result.reasonCodes.none { it.endsWith("_read_failed") || it.startsWith("node_") })
        assertTrue(result.reasonCodes.all { it in CONTRACT_REASON_CODES })
    }

    private fun capture(
        windows: List<FakeWindow>,
        expectedTitleHash: String = EXPECTED_HASH,
        revision: Long = 1,
        captureToken: String = "c1",
        at: Instant = FIRST_AT,
        limits: C1bProbeLimits = C1bProbeLimits(),
    ): C1bRawFrame = probe(FakePort(revision = revision, windowList = windows), limits, at)
        .capture(request(captureToken, expectedTitleHash))

    private fun probe(
        port: FakePort,
        limits: C1bProbeLimits = C1bProbeLimits(),
        at: Instant = FIRST_AT,
    ): TabletC1bProbe = TabletC1bProbe(port, limits) { at }

    private fun request(
        captureToken: String = "c1",
        expectedTitleHash: String = EXPECTED_HASH,
    ): C1bCaptureRequest = C1bCaptureRequest("capture-$captureToken", captureToken, expectedTitleHash)

    private fun assembler(): TabletC1bAssembler = TabletC1bAssembler()

    private fun assemblyRequest(expectedTitleHash: String = EXPECTED_HASH): C1bAssemblyRequest = C1bAssemblyRequest(
        runId = "tl1-c1b-unit",
        expectedTitleHash = expectedTitleHash,
        provenance = C1bProvenance(
            kind = "offline_fixture",
            name = "tablet-c1b-unit",
            producerCommitSha = "a".repeat(40),
            producerArtifactSha256 = "sha256:" + "b".repeat(64),
        ),
        upstreamT0 = C1bUpstreamT0(
            sourceKind = "offline_fixture",
            runId = "t0-unit",
            capturedAt = "2026-08-26T00:00:00.0000000Z",
            artifactSha256 = "sha256:" + "c".repeat(64),
            producerCommitSha = "d".repeat(40),
            deviceProfileHash = "sha256:" + "e".repeat(64),
            readinessReasons = listOf("layout_observation_required"),
            p0UnsupportedReasons = listOf(
                "wechat_layout_unverified",
                "tablet_landscape_p0_unimplemented",
            ),
        ),
    )

    private fun window(
        rawId: Int,
        root: FakeNode?,
        bounds: C1bRect = FULL,
        title: CharSequence? = EXPECTED_TITLE,
        focused: Boolean = false,
    ): FakeWindow = FakeWindow(
        rawId = rawId,
        typeCode = 1,
        bounds = bounds,
        touchableBounds = bounds,
        focused = focused,
        title = title,
        root = root,
    )

    private fun node(
        token: Long,
        windowId: Int,
        bounds: C1bRect = FULL,
        visible: Boolean = true,
        enabled: Boolean = true,
        editable: Boolean = false,
        focused: Boolean = false,
        packageName: String? = C1B_WECHAT_PACKAGE,
        refreshResult: Boolean = true,
        children: List<FakeNode?> = emptyList(),
    ): FakeNode = FakeNode(
        token = token,
        windowId = windowId,
        bounds = bounds,
        visible = visible,
        enabled = enabled,
        editable = editable,
        focused = focused,
        packageName = packageName,
        refreshResult = refreshResult,
    ).also { it.children += children }

    private class FakeWindow(
        val rawId: Int,
        val typeCode: Int,
        val displayId: Int = 0,
        val layer: Int = 1,
        val bounds: C1bRect? = FULL,
        val touchableBounds: C1bRect? = bounds,
        val active: Boolean = false,
        val focused: Boolean = false,
        val title: CharSequence?,
        val root: FakeNode?,
    ) : C1bWindowHandle

    private class FakeNode(
        val token: Long,
        val windowId: Int,
        val bounds: C1bRect?,
        val visible: Boolean,
        val enabled: Boolean,
        val editable: Boolean,
        val scrollable: Boolean = false,
        val focused: Boolean,
        val packageName: String? = C1B_WECHAT_PACKAGE,
        val refreshResult: Boolean = true,
    ) : C1bNodeHandle {
        val children = mutableListOf<FakeNode?>()
    }

    private class FakePort(
        private val revision: Long = 1,
        private val windowList: List<FakeWindow>,
        private val directFocus: FakeNode? = null,
        private val throwingChildren: Set<Pair<Long, Int>> = emptySet(),
        private val throwingWindowFocusIds: Set<Int> = emptySet(),
        private val throwingWindowDisplayIds: Set<Int> = emptySet(),
        private val throwingWindowTypeIds: Set<Int> = emptySet(),
        private val throwingWindowLayerIds: Set<Int> = emptySet(),
        private val throwingTouchableBoundsIds: Set<Int> = emptySet(),
        private val throwingWindowActiveIds: Set<Int> = emptySet(),
        private val throwingNodeFacts: Map<Long, Set<String>> = emptyMap(),
    ) : TabletC1bReadPort {
        var refreshCalls: Int = 0
        var inputFocusCalls: Int = 0

        override fun currentRevision(): Long = revision
        override fun display(): C1bDisplayRead = C1bDisplayRead(0, 2_800, 1_968)
        override fun windows(): List<C1bWindowHandle> = windowList
        override fun windowId(window: C1bWindowHandle): Int = window.fake.rawId
        override fun platformTypeCode(window: C1bWindowHandle): Int {
            if (window.fake.rawId in throwingWindowTypeIds) error("synthetic window type read failure")
            return window.fake.typeCode
        }
        override fun windowDisplayId(window: C1bWindowHandle): Int {
            if (window.fake.rawId in throwingWindowDisplayIds) error("synthetic window display read failure")
            return window.fake.displayId
        }
        override fun windowLayer(window: C1bWindowHandle): Int {
            if (window.fake.rawId in throwingWindowLayerIds) error("synthetic window layer read failure")
            return window.fake.layer
        }
        override fun windowBounds(window: C1bWindowHandle): C1bRect? = window.fake.bounds
        override fun windowTouchableBounds(window: C1bWindowHandle): C1bRect? {
            if (window.fake.rawId in throwingTouchableBoundsIds) error("synthetic touchable bounds read failure")
            return window.fake.touchableBounds
        }
        override fun windowActive(window: C1bWindowHandle): Boolean {
            if (window.fake.rawId in throwingWindowActiveIds) error("synthetic window active read failure")
            return window.fake.active
        }
        override fun windowFocused(window: C1bWindowHandle): Boolean {
            if (window.fake.rawId in throwingWindowFocusIds) error("synthetic window focus read failure")
            return window.fake.focused
        }
        override fun windowExpectedTitleMatch(
            window: C1bWindowHandle,
            expectedTitleHash: String,
        ): C1bTitleMatchStatus = c1bMatchWindowTitle(window.fake.title, expectedTitleHash)

        override fun root(window: C1bWindowHandle): C1bNodeHandle? = window.fake.root
        override fun nodesExactlyEqual(first: C1bNodeHandle, second: C1bNodeHandle): Boolean =
            first.fake === second.fake
        override fun nodeRefresh(node: C1bNodeHandle): Boolean {
            refreshCalls += 1
            return node.fake.refreshResult
        }

        override fun nodeWindowId(node: C1bNodeHandle): Int = nodeFact(node, "window_id") { it.windowId }
        override fun nodePackageName(node: C1bNodeHandle): String? = nodeFact(node, "package") { it.packageName }
        override fun nodeBounds(node: C1bNodeHandle): C1bRect? = nodeFact(node, "bounds") { it.bounds }
        override fun nodeVisible(node: C1bNodeHandle): Boolean = nodeFact(node, "visible") { it.visible }
        override fun nodeEnabled(node: C1bNodeHandle): Boolean = nodeFact(node, "enabled") { it.enabled }
        override fun nodeEditable(node: C1bNodeHandle): Boolean = nodeFact(node, "editable") { it.editable }
        override fun nodeScrollable(node: C1bNodeHandle): Boolean = node.fake.scrollable
        override fun nodeFocused(node: C1bNodeHandle): Boolean = nodeFact(node, "focused") { it.focused }
        override fun nodeChildCount(node: C1bNodeHandle): Int = node.fake.children.size
        override fun nodeChild(node: C1bNodeHandle, index: Int): C1bNodeHandle? {
            if ((node.fake.token to index) in throwingChildren) error("synthetic child read failure")
            return node.fake.children[index]
        }

        override fun inputFocusNode(): C1bNodeHandle? {
            inputFocusCalls += 1
            return directFocus
        }

        private fun <T> nodeFact(node: C1bNodeHandle, name: String, read: (FakeNode) -> T): T {
            val fake = node.fake
            if (name in throwingNodeFacts[fake.token].orEmpty()) error("synthetic $name read failure")
            return read(fake)
        }

        private val C1bWindowHandle.fake: FakeWindow get() = this as FakeWindow
        private val C1bNodeHandle.fake: FakeNode get() = this as FakeNode
    }

    private companion object {
        const val EXPECTED_TITLE = "Expected conversation"
        val EXPECTED_HASH: String = sha256(EXPECTED_TITLE)
        val FIRST_AT: Instant = Instant.parse("2026-08-26T00:00:01.0000000Z")
        val SECOND_AT: Instant = Instant.parse("2026-08-26T00:00:02.0000000Z")
        val FULL = C1bRect(0, 0, 2_800, 1_968)
        val LEFT = C1bRect(0, 0, 900, 1_968)
        val RIGHT = C1bRect(900, 0, 2_800, 1_968)
        val CONTRACT_REASON_CODES = setOf(
            "runtime_producer_unavailable", "fixture_origin_required", "route_contract_violation",
            "safety_constants_invalid", "privacy_contract_violation", "raw_identity_persisted",
            "chat_plaintext_persisted", "chat_content_digest_persisted", "duplicate_json_property",
            "json_number_not_int64", "json_schema_validation_failed", "capture_order_invalid",
            "capture_in_future", "capture_stale", "capture_span_exceeded", "atomic_capture_revision_invalid",
            "display_unknown", "not_landscape", "multi_display_blocked", "window_inventory_truncated",
            "window_count_not_two", "window_label_invalid", "window_label_duplicate",
            "window_identity_replacement", "window_geometry_invalid", "window_root_owner_conflict",
            "window_type_invalid", "root_window_binding_invalid", "subtree_capture_incomplete",
            "subtree_counts_invalid", "semantic_subtree_opaque", "window_title_probe_invalid",
            "pane_projection_invalid", "window_root_projection_invalid", "pane_semantic_roles_unverified",
            "node_binding_invalid", "focus_inventory_invalid", "ime_inventory_invalid",
            "ime_hidden_unverified", "capture_semantics_drift", "consistency_declared_mismatch",
            "declared_status_mismatch", "declared_reasons_incomplete", "tablet_layout_diagnostic_only",
            "target_conversation_unverified", "target_regions_unverified", "validation_exception",
        )

        fun sha256(value: String): String = "sha256:" + MessageDigest.getInstance("SHA-256")
            .digest(value.toByteArray(StandardCharsets.UTF_8))
            .joinToString("") { "%02x".format(it) }

        fun allJsonKeys(value: Any?): Set<String> = when (value) {
            is org.json.JSONObject -> value.keySet().flatMapTo(linkedSetOf()) { key ->
                setOf(key) + allJsonKeys(value.opt(key))
            }
            is org.json.JSONArray -> (0 until value.length()).flatMapTo(linkedSetOf()) { index ->
                allJsonKeys(value.opt(index))
            }
            else -> emptySet()
        }

        fun expectFailure(block: () -> Unit) {
            try {
                block()
                throw AssertionError("expected failure")
            } catch (_: IllegalArgumentException) {
                // expected
            }
        }
    }
}
