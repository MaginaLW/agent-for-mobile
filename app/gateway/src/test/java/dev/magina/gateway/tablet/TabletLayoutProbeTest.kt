package dev.magina.gateway.tablet

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.format.DateTimeFormatterBuilder

class TabletLayoutProbeTest {

    @Test
    fun twoWechatWindowsAreAllReportedAndLabelsSurviveWindowReordering() {
        val first = frame(
            revision = 10,
            token = "c1",
            windows = listOf(
                window(rawId = NAV_ID, bounds = NAV_BOUNDS, nodes = listOf(listNode())),
                window(rawId = CHAT_ID, bounds = CHAT_BOUNDS, nodes = chatNodes()),
            ),
        )
        val second = frame(
            revision = 11,
            token = "c2",
            windows = listOf(
                window(rawId = CHAT_ID, bounds = CHAT_BOUNDS, nodes = chatNodes()),
                window(rawId = NAV_ID, bounds = NAV_BOUNDS, nodes = listOf(listNode())),
            ),
        )

        val result = TabletLayoutProbe.assemble(context(), listOf(first, second))
        val firstByBounds = result.frames[0].windows.associate { it.bounds to it.windowLabel }
        val secondByBounds = result.frames[1].windows.associate { it.bounds to it.windowLabel }

        assertEquals(2, result.frames[0].windows.size)
        assertEquals(2, result.frames[1].windows.size)
        assertEquals(firstByBounds, secondByBounds)
        assertTrue(result.consistency.stable)
        assertFalse("window_identity_replacement" in result.consistency.reasonCodes)
        result.frames.flatMap { it.windows }.forEach {
            assertEquals("application", it.type)
            assertEquals(WECHAT_PACKAGE, it.rootPackage)
        }
    }

    @Test
    fun focusAbsentAndImeHiddenRemainDiagnosticAndNeverGrantActions() {
        val result = TabletLayoutProbe.assemble(
            context(),
            listOf(
                normalFrame(20, "c1", inputFocused = false, windowFocused = false),
                normalFrame(21, "c2", inputFocused = false, windowFocused = false),
            ),
        )
        val json = result.toJson()

        assertTrue(result.frames.all { it.target.focus.status == "absent" })
        assertTrue(result.frames.all { it.target.ime.binding == "not_active" })
        assertFalse(json.getBoolean("layout_accepted"))
        assertFalse(json.getBoolean("wechat_layout_verified"))
        assertFalse(json.getBoolean("editor_action_ready"))
        assertEquals("unsupported", json.getString("p0_capability"))
        assertFalse(json.getBoolean("execution_grant"))
        assertFalse(json.getJSONObject("route").getBoolean("device_action_allowed"))
        assertFalse(json.getJSONObject("route").getBoolean("settings_mutation_allowed"))
    }

    @Test
    fun otherOwnerIsReportedWithoutSelectingOrGrantingIt() {
        val other = window(
            rawId = NAV_ID,
            bounds = NAV_BOUNDS,
            owner = "com.example.other",
            focused = true,
            nodes = listOf(listNode()),
        )
        val frames = listOf(
            frame(30, "c1", listOf(other, window(CHAT_ID, CHAT_BOUNDS, nodes = listOf(inputNode())))),
            frame(31, "c2", listOf(other, window(CHAT_ID, CHAT_BOUNDS, nodes = listOf(inputNode())))),
        )

        val result = TabletLayoutProbe.assemble(context(), frames)
        val codes = result.reasonCodes.toSet()

        assertTrue("window_root_owner_conflict" in codes)
        assertTrue("focus_target_conflict" in codes)
        assertFalse(result.toJson().getBoolean("execution_grant"))
    }

    @Test
    fun replacementIdentityWithSameBoundsGetsANewLabelAndBlocksConsistency() {
        val first = normalFrame(40, "c1")
        val replaced = frame(
            revision = 41,
            token = "c2",
            windows = listOf(
                window(rawId = REPLACEMENT_NAV_ID, bounds = NAV_BOUNDS, nodes = listOf(listNode())),
                window(rawId = CHAT_ID, bounds = CHAT_BOUNDS, nodes = chatNodes()),
            ),
        )

        val result = TabletLayoutProbe.assemble(context(), listOf(first, replaced))
        val firstNav = result.frames[0].windows.single { it.bounds == NAV_BOUNDS }.windowLabel
        val secondNav = result.frames[1].windows.single { it.bounds == NAV_BOUNDS }.windowLabel

        assertNotEquals(firstNav, secondNav)
        assertFalse(result.consistency.stable)
        assertTrue("window_identity_replacement" in result.reasonCodes)
    }

    @Test
    fun titleAndInputInDifferentWindowsKeepOwnershipAndUseTitleSpecificDiagnostics() {
        val crossWindow = listOf(
            window(rawId = NAV_ID, bounds = NAV_BOUNDS, nodes = listOf(titleNode(NAV_TITLE_BOUNDS))),
            window(rawId = CHAT_ID, bounds = CHAT_BOUNDS, nodes = listOf(inputNode())),
        )
        val result = TabletLayoutProbe.assemble(
            context(),
            listOf(frame(50, "c1", crossWindow), frame(51, "c2", crossWindow)),
        )
        val target = result.frames.first().target

        assertEquals(1, target.titleCandidates.size)
        assertEquals(1, target.inputCandidates.size)
        assertNotEquals(target.titleCandidates.single().windowLabel, target.inputCandidates.single().windowLabel)
        assertTrue("title_wrong_window" in result.reasonCodes)
        assertTrue("title_wrong_pane" in result.reasonCodes)
        assertFalse("cross_window_region" in result.reasonCodes)
        assertTrue(result.frames.flatMap { it.nodeObservations }.all { it.windowLabel.startsWith("aw") })
        assertTrue(result.frames.flatMap { it.nodeObservations }.all { it.paneLabel?.startsWith("ap") == true })
    }

    @Test
    fun everyMatchingTitleCandidateIsReportedAcrossWindows() {
        val windows = listOf(
            window(rawId = NAV_ID, bounds = NAV_BOUNDS, nodes = listOf(titleNode(NAV_TITLE_BOUNDS))),
            window(rawId = CHAT_ID, bounds = CHAT_BOUNDS, nodes = chatNodes()),
        )
        val result = TabletLayoutProbe.assemble(
            context(),
            listOf(frame(60, "c1", windows), frame(61, "c2", windows)),
        )

        val matches = result.frames.first().target.titleCandidates
        assertEquals(2, matches.size)
        assertEquals(2, matches.map { it.windowLabel }.distinct().size)
        assertTrue(matches.all { it.labelHash == EXPECTED_TITLE_HASH })
    }

    @Test
    fun rawWindowIdsAndStableWindowHashesNeverReachJson() {
        val result = TabletLayoutProbe.assemble(
            context(),
            listOf(normalFrame(70, "c1"), normalFrame(71, "c2")),
        )
        val json = result.toJson()
        val rendered = json.toString()
        val allKeys = mutableSetOf<String>()
        collectKeys(json, allKeys)

        assertFalse(rendered.contains(NAV_ID.toString()))
        assertFalse(rendered.contains(CHAT_ID.toString()))
        val declaredFalsePrivacyKeys = setOf(
            "raw_dump_persisted",
            "raw_screenshot_persisted",
            "raw_window_identity_persisted",
            "raw_node_identity_persisted",
        )
        assertTrue(allKeys.none { it.contains("raw", ignoreCase = true) && it !in declaredFalsePrivacyKeys })
        assertFalse(json.getJSONObject("privacy").getBoolean("raw_window_identity_persisted"))
        assertFalse(json.getJSONObject("privacy").getBoolean("raw_node_identity_persisted"))
        result.frames.flatMap { it.windows }.forEach { assertTrue(it.windowLabel.matches(Regex("aw[1-9][0-9]*"))) }
    }

    @Test
    fun inputFingerprintIsStableOnlyWithinTheSameRunSaltAndIdentity() {
        val frames = listOf(normalFrame(80, "c1"), normalFrame(81, "c2"))
        val firstRun = TabletLayoutProbe.assemble(context(saltByte = 7), frames)
        val secondRun = TabletLayoutProbe.assemble(context(saltByte = 8), frames)
        val firstHashes = firstRun.frames.map { it.target.inputCandidates.single().editorFingerprintHash }
        val secondHash = secondRun.frames.first().target.inputCandidates.single().editorFingerprintHash

        assertEquals(firstHashes[0], firstHashes[1])
        assertNotEquals(firstHashes[0], secondHash)
        assertFalse(firstRun.toJson().toString().contains(ByteArray(32) { 7 }.joinToString("")))
    }

    @Test
    fun revisionDriftFailsAtomicCaptureWithoutWaitingOrRetrying() {
        val drifting = normalFrame(90, "c1").copy(layoutRevision = 91, revisionAfter = 91)
        val result = TabletLayoutProbe.assemble(
            context(),
            listOf(drifting, normalFrame(92, "c2")),
        )

        assertFalse(result.consistency.stable)
        assertTrue("atomic_capture_revision_invalid" in result.reasonCodes)
        assertFalse(result.toJson().getBoolean("execution_grant"))
    }

    @Test
    fun isolatedProductionCapabilityNeverTouchesPhoneOrActionPath() {
        assertFalse(TabletLayoutProbeProductionCapability.available)
        assertFalse(TabletLayoutProbeProductionCapability.runtimeAttested)
        assertFalse(TabletLayoutProbeProductionCapability.actionGrant)
        assertFalse(TabletLayoutProbeProductionCapability.p0Supported)
        assertEquals("runtime_runner_not_connected", TabletLayoutProbeProductionCapability.reason)

        // 这里能构造的唯一 production 状态是 unavailable；没有 ForegroundWindowTracker、手机
        // applicationWindow/P0 validator 或任意 mutation callback 可传入本隔离 core。
        val result = TabletLayoutProbe.assemble(
            context(),
            listOf(normalFrame(100, "c1"), normalFrame(101, "c2")),
        )
        assertFalse(result.toJson().getJSONObject("provenance").getBoolean("runtime_attested"))
        assertFalse(result.toJson().getBoolean("execution_grant"))
    }

    @Test
    fun jsonShapeMatchesTheClosedV2ContractBoundary() {
        val json = TabletLayoutProbe.assemble(
            context(),
            listOf(normalFrame(110, "c1"), normalFrame(111, "c2")),
        ).toJson()
        assertEquals(
            setOf(
                "schema", "run_id", "captured_at", "mode", "provenance", "upstream_t0", "route",
                "privacy", "frames", "consistency", "diagnostic_status", "reason_codes",
                "layout_accepted", "wechat_layout_verified", "editor_action_ready", "p0_capability",
                "p0_blockers", "execution_grant",
            ),
            keysOf(json),
        )
        val frame = json.getJSONArray("frames").getJSONObject(0)
        assertEquals(
            setOf(
                "capture_id", "captured_at", "capture", "display", "a11y_windows", "windows_truncated",
                "panes", "panes_truncated", "node_observations", "nodes_truncated", "target",
            ),
            keysOf(frame),
        )
        val target = frame.getJSONObject("target")
        assertEquals(
            setOf(
                "expected_title_hash", "conversation_window_label", "conversation_pane_label",
                "title_candidates", "toolbar_candidates", "message_candidates", "input_candidates",
                "focus", "ime",
            ),
            keysOf(target),
        )
        assertEquals(
            setOf(
                "hash_algorithm", "raw_window_identity_persisted", "raw_node_identity_persisted",
                "chat_plaintext_persisted", "raw_screenshot_persisted", "raw_dump_persisted",
                "whole_screen_ocr_persisted",
            ),
            keysOf(json.getJSONObject("privacy")),
        )
        assertEquals(
            setOf(
                "window_label", "identity_namespace", "display_id", "type", "root_package", "layer",
                "bounds", "touchable_bounds", "root_status", "active", "focused",
            ),
            keysOf(frame.getJSONArray("a11y_windows").getJSONObject(0)),
        )
        assertEquals(
            setOf("pane_label", "window_label", "role", "bounds", "binding"),
            keysOf(frame.getJSONArray("panes").getJSONObject(0)),
        )
        assertEquals(
            setOf(
                "node_label", "window_label", "pane_label", "role", "bounds", "visible", "enabled",
                "clickable", "long_clickable", "editable", "scrollable", "checkable", "focused",
            ),
            keysOf(frame.getJSONArray("node_observations").getJSONObject(0)),
        )
        assertEquals(
            setOf(
                "candidate_label", "node_label", "label_hash", "semantic_role", "source", "bounds",
                "window_label", "pane_label", "capture_token",
            ),
            keysOf(target.getJSONArray("title_candidates").getJSONObject(0)),
        )
        assertEquals(
            setOf(
                "candidate_label", "source_node_labels", "window_label", "pane_label", "bounds",
                "capture_token",
            ),
            keysOf(target.getJSONArray("toolbar_candidates").getJSONObject(0)),
        )
        assertEquals(
            setOf(
                "candidate_label", "node_label", "node_package", "window_label", "pane_label", "bounds",
                "capture_token", "editable", "focused", "editor_fingerprint_hash",
            ),
            keysOf(target.getJSONArray("input_candidates").getJSONObject(0)),
        )
    }

    @Test
    fun allInteractiveWindowsAreLabeledButOnlyApplicationsProducePanesAndNodes() {
        val overlayCanary = node(role = "other", bounds = CHAT_TOOLBAR_BOUNDS)
        val windows = listOf(
            window(NAV_ID, NAV_BOUNDS, nodes = listOf(listNode())),
            window(CHAT_ID, CHAT_BOUNDS, nodes = chatNodes()),
            window(
                rawId = 61_234_567,
                bounds = CHAT_TOOLBAR_BOUNDS,
                owner = "dev.magina.gateway",
                type = "accessibility_overlay",
                layer = 20,
                nodes = listOf(overlayCanary),
            ).copy(touchableBounds = ProbeRect(0, 1000, 100, 1100)),
            window(
                rawId = 62_234_567,
                bounds = ProbeRect(0, 0, 2800, 80),
                owner = "com.android.systemui",
                type = "system",
                layer = 30,
                nodes = emptyList(),
            ),
            window(
                rawId = 63_234_567,
                bounds = ProbeRect(0, 1500, 2800, 1968),
                owner = "com.example.ime",
                type = "input_method",
                layer = 15,
                nodes = emptyList(),
            ),
        )
        val result = TabletLayoutProbe.assemble(
            context(),
            listOf(frame(120, "c1", windows), frame(121, "c2", windows)),
        )
        val first = result.frames.first()

        assertEquals(
            setOf("application", "accessibility_overlay", "system", "input_method"),
            first.windows.map { it.type }.toSet(),
        )
        assertEquals(2, first.panes.size)
        assertEquals(5, first.nodeObservations.size)
        assertTrue(first.nodeObservations.all { node ->
            first.windows.single { it.windowLabel == node.windowLabel }.type == "application"
        })
        assertTrue("overlay_target_occlusion" in result.reasonCodes)
    }

    @Test
    fun extraDisplayOnAnyInteractiveWindowBlocksTheFrame() {
        val windows = listOf(
            window(NAV_ID, NAV_BOUNDS, nodes = listOf(listNode())),
            window(CHAT_ID, CHAT_BOUNDS, nodes = chatNodes()),
            window(
                rawId = 64_234_567,
                bounds = ProbeRect(0, 0, 1000, 600),
                owner = "com.android.systemui",
                type = "system",
                displayId = 1,
                nodes = emptyList(),
            ),
        )
        val result = TabletLayoutProbe.assemble(
            context(),
            listOf(frame(130, "c1", windows), frame(131, "c2", windows)),
        )

        assertTrue("multi_display_blocked" in result.reasonCodes)
        assertTrue(result.frames.first().windows.any { it.displayId == 1 })
    }

    @Test
    fun structuralToolbarProofBindsTitleAndContainerWithoutTrustingSameNameRows() {
        val result = TabletLayoutProbe.assemble(
            context(),
            listOf(normalFrame(140, "c1"), normalFrame(141, "c2")),
        )
        val frame = result.frames.first()
        val title = frame.target.titleCandidates.single()
        val titleNode = frame.nodeObservations.single { it.nodeLabel == title.nodeLabel }
        val toolbar = frame.target.toolbarCandidates.single()
        val toolbarSource = frame.nodeObservations.single { it.nodeLabel in toolbar.sourceNodeLabels }

        assertEquals("pane_toolbar_title", title.semanticRole)
        assertEquals("toolbar_title", titleNode.role)
        assertEquals(title.bounds, titleNode.bounds)
        assertEquals(title.windowLabel, titleNode.windowLabel)
        assertEquals(title.paneLabel, titleNode.paneLabel)
        assertEquals("container", toolbarSource.role)
        assertEquals(toolbar.bounds, toolbarSource.bounds)
        assertEquals("observed", result.diagnosticStatus)
        assertTrue(result.reasonCodes.isEmpty())
    }

    @Test
    fun nonTargetChatCanaryPlaintextAndStableDigestNeverReachJson() {
        val chatCanary = "非目标聊天 canary 9bd692f2"
        val stableCanaryHash = probeContentHash(chatCanary)
        val unrelatedNode = node(
            role = "other",
            bounds = ProbeRect(20, 300, 900, 360),
            hashes = setOf(stableCanaryHash),
        )
        val windows = listOf(
            window(NAV_ID, NAV_BOUNDS, nodes = listOf(listNode(), unrelatedNode)),
            window(CHAT_ID, CHAT_BOUNDS, nodes = chatNodes()),
        )
        val result = TabletLayoutProbe.assemble(
            context(),
            listOf(frame(150, "c1", windows), frame(151, "c2", windows)),
        )
        val rendered = result.toJson().toString()

        assertFalse(rendered.contains(chatCanary))
        assertFalse(rendered.contains(stableCanaryHash))
        assertFalse(rendered.contains("content_hash"))
        assertFalse(rendered.contains("text_hash"))
        assertFalse(rendered.contains("description_hash"))
    }

    @Test
    fun saltIsCopiedAndInvalidSaltOrExpectedHashIsRejectedWithoutLeakingCallerText() {
        val mutableSalt = ByteArray(32) { 3 }
        val copiedContext = context(runSalt = mutableSalt)
        mutableSalt.fill(9)
        val copiedHash = TabletLayoutProbe.assemble(
            copiedContext,
            listOf(normalFrame(160, "c1"), normalFrame(161, "c2")),
        ).frames.first().target.inputCandidates.single().editorFingerprintHash
        val originalHash = TabletLayoutProbe.assemble(
            context(runSalt = ByteArray(32) { 3 }),
            listOf(normalFrame(160, "c1"), normalFrame(161, "c2")),
        ).frames.first().target.inputCandidates.single().editorFingerprintHash
        assertEquals(originalHash, copiedHash)
        val anotherRunHash = TabletLayoutProbe.assemble(
            context(runId = "tl1-v2-other-run", runSalt = ByteArray(32) { 3 }),
            listOf(normalFrame(160, "c1"), normalFrame(161, "c2")),
        ).frames.first().target.inputCandidates.single().editorFingerprintHash
        assertNotEquals(originalHash, anotherRunHash)

        val callerPlaintext = "not-a-hash-secret-title"
        val invalidHash = assertThrows(IllegalArgumentException::class.java) {
            TabletLayoutProbe.assemble(
                context(expectedTitleHash = callerPlaintext),
                listOf(normalFrame(162, "c1"), normalFrame(163, "c2")),
            )
        }
        val emptySalt = assertThrows(IllegalArgumentException::class.java) {
            TabletLayoutProbe.assemble(
                context(runSalt = byteArrayOf()),
                listOf(normalFrame(162, "c1"), normalFrame(163, "c2")),
            )
        }
        assertThrows(IllegalArgumentException::class.java) {
            context(runSalt = ByteArray(33))
        }
        assertFalse(invalidHash.message.orEmpty().contains(callerPlaintext))
        assertFalse(emptySalt.message.orEmpty().contains(callerPlaintext))
    }

    @Test
    fun captureTimeExpectedTitleHashMustMatchTheRunContextBeforeCandidatesAreBuilt() {
        val hashABoundFrames = listOf(normalFrame(164, "c1"), normalFrame(165, "c2"))
        assertTrue(hashABoundFrames.all { it.captureExpectedTitleHash == EXPECTED_TITLE_HASH })

        val observed = TabletLayoutProbe.assemble(context(), hashABoundFrames)
        assertTrue(observed.frames.flatMap { it.target.titleCandidates }.isNotEmpty())
        assertTrue(observed.frames.flatMap { it.target.titleCandidates }
            .all { it.labelHash == EXPECTED_TITLE_HASH })
        assertFalse(observed.toJson().toString().contains("capture_expected_title_hash"))

        assertThrows(IllegalArgumentException::class.java) {
            TabletLayoutProbe.assemble(context(expectedTitleHash = HASH_B), hashABoundFrames)
        }
        assertThrows(IllegalArgumentException::class.java) {
            TabletLayoutProbe.assemble(
                context(),
                hashABoundFrames.map { it.copy(captureExpectedTitleHash = null) },
            )
        }
        assertThrows(IllegalArgumentException::class.java) {
            TabletLayoutProbe.assemble(
                context(),
                hashABoundFrames.map { it.copy(captureExpectedTitleHash = "invalid") },
            )
        }
    }

    @Test
    fun inventoryLimitsStaySchemaBoundedAndSetTheirOwnBlockingFlags() {
        val manyApplications = (1..9).map { index ->
            window(
                rawId = 10_000 + index,
                bounds = ProbeRect(index * 10, 0, index * 10 + 100, 100),
                nodes = if (index == 1) List(513) { node("other", ProbeRect(0, 0, 1, 1)) } else emptyList(),
            )
        }
        val otherWindows = (1..10).map { index ->
            window(
                rawId = 20_000 + index,
                bounds = ProbeRect(0, index * 10, 100, index * 10 + 10),
                owner = "com.android.systemui",
                type = "system",
                layer = index,
                nodes = emptyList(),
            )
        }
        val windows = manyApplications + otherWindows
        val result = TabletLayoutProbe.assemble(
            context(),
            listOf(frame(170, "c1", windows), frame(171, "c2", windows)),
        )
        val first = result.frames.first()

        assertEquals(16, first.windows.size)
        assertEquals(8, first.panes.size)
        assertEquals(512, first.nodeObservations.size)
        assertTrue(first.windowsTruncated)
        assertTrue(first.panesTruncated)
        assertTrue(first.nodesTruncated)
        assertTrue("window_inventory_truncated" in result.reasonCodes)
        assertTrue("pane_inventory_truncated" in result.reasonCodes)
        assertTrue("node_inventory_truncated" in result.reasonCodes)
        assertTrue(first.windows.all { it.windowLabel.matches(Regex("aw[1-9][0-9]{0,2}")) })
    }

    @Test
    fun semanticConsistencyIncludesTargetRegionsFocusImeAndTruncation() {
        val first = normalFrame(180, "c1")
        val driftedChat = window(
            rawId = CHAT_ID,
            bounds = CHAT_BOUNDS,
            nodes = listOf(
                toolbarContainerNode(), titleNode(), chatMessageNode(ProbeRect(1400, 180, 2800, 1790)),
                inputNode(bounds = ProbeRect(1400, 1790, 2800, 1968)),
            ),
        )
        val second = frame(
            181,
            "c2",
            listOf(window(NAV_ID, NAV_BOUNDS, nodes = listOf(listNode())), driftedChat),
        )
        val result = TabletLayoutProbe.assemble(context(), listOf(first, second))

        assertFalse(result.consistency.stable)
        assertTrue("capture_semantics_drift" in result.consistency.reasonCodes)
    }

    @Test
    fun focusRequiresTheFocusedApplicationAndFocusedEditorToAgree() {
        val inputWithoutWindow = TabletLayoutProbe.assemble(
            context(),
            listOf(normalFrame(190, "c1", inputFocused = true), normalFrame(191, "c2", inputFocused = true)),
        )
        val windowWithoutInput = TabletLayoutProbe.assemble(
            context(),
            listOf(
                normalFrame(192, "c1", windowFocused = true),
                normalFrame(193, "c2", windowFocused = true),
            ),
        )
        assertTrue("focus_target_conflict" in inputWithoutWindow.reasonCodes)
        assertTrue("focus_target_conflict" in windowWithoutInput.reasonCodes)

        val navFocusedWindows = listOf(
            window(NAV_ID, NAV_BOUNDS, focused = true, nodes = listOf(listNode())),
            window(CHAT_ID, CHAT_BOUNDS, nodes = chatNodes()),
        )
        val navFocused = TabletLayoutProbe.assemble(
            context(),
            listOf(frame(196, "c1", navFocusedWindows), frame(197, "c2", navFocusedWindows)),
        )
        assertTrue("focus_target_conflict" in navFocused.reasonCodes)

        val consistentHiddenIme = TabletLayoutProbe.assemble(
            context(),
            listOf(
                normalFrame(194, "c1", inputFocused = true, windowFocused = true),
                normalFrame(195, "c2", inputFocused = true, windowFocused = true),
            ),
        ).frames.first().target.ime
        assertFalse(consistentHiddenIme.visible)
        assertEquals(ProbeImeMode.NONE, consistentHiddenIme.mode)
        assertNull(consistentHiddenIme.bounds)
        assertNull(consistentHiddenIme.editorFingerprintHash)
        assertNull(consistentHiddenIme.targetInputCandidateLabel)
        assertEquals("not_active", consistentHiddenIme.binding)

        assertThrows(IllegalArgumentException::class.java) {
            TabletLayoutProbe.assemble(
                context(),
                listOf(
                    normalFrame(198, "c1").copy(
                        ime = RawProbeIme(false, ProbeImeMode.DOCKED, ProbeRect(0, 1500, 2800, 1968)),
                    ),
                    normalFrame(199, "c2").copy(
                        ime = RawProbeIme(false, ProbeImeMode.DOCKED, ProbeRect(0, 1500, 2800, 1968)),
                    ),
                ),
            )
        }
    }

    @Test
    fun visibleImeRequiresAnExactInteractiveInputMethodWindowBinding() {
        fun imeWindow(
            rawId: Int = 66_234_567,
            bounds: ProbeRect = IME_BOUNDS,
            displayId: Int? = 0,
        ) = window(
            rawId = rawId,
            bounds = bounds,
            owner = "com.example.ime",
            type = "input_method",
            displayId = displayId,
            layer = 10,
            nodes = emptyList(),
        )

        fun visibleFrame(
            revision: Long,
            token: String,
            imeWindows: List<RawTabletWindow>,
            targetBounds: ProbeRect? = IME_BOUNDS,
        ): RawTabletProbeFrame {
            val appFrame = normalFrame(revision, token, inputFocused = true, windowFocused = true)
            return appFrame.copy(
                interactiveWindows = appFrame.interactiveWindows + imeWindows,
                ime = RawProbeIme(true, ProbeImeMode.DOCKED, targetBounds),
            )
        }

        val bound = TabletLayoutProbe.assemble(
            context(),
            listOf(
                visibleFrame(198, "c1", listOf(imeWindow())),
                visibleFrame(199, "c2", listOf(imeWindow())),
            ),
        )
        assertTrue(bound.reasonCodes.isEmpty())
        assertEquals("target_editor", bound.frames.first().target.ime.binding)

        val missing = TabletLayoutProbe.assemble(
            context(),
            listOf(visibleFrame(200, "c1", emptyList()), visibleFrame(201, "c2", emptyList())),
        )
        assertEquals(listOf("ime_target_editor_unbound"), missing.reasonCodes)

        val multipleImeWindows = listOf(imeWindow(), imeWindow(rawId = 67_234_567))
        val multiple = TabletLayoutProbe.assemble(
            context(),
            listOf(
                visibleFrame(202, "c1", multipleImeWindows),
                visibleFrame(203, "c2", multipleImeWindows),
            ),
        )
        assertEquals(listOf("ime_target_editor_unbound"), multiple.reasonCodes)

        val wrongDisplay = TabletLayoutProbe.assemble(
            context(),
            listOf(
                visibleFrame(204, "c1", listOf(imeWindow(displayId = 1))),
                visibleFrame(205, "c2", listOf(imeWindow(displayId = 1))),
            ),
        )
        assertEquals(listOf("ime_target_editor_unbound", "multi_display_blocked"), wrongDisplay.reasonCodes)

        val mismatchedBounds = ProbeRect(0, 1400, 2800, 1968)
        val mismatch = TabletLayoutProbe.assemble(
            context(),
            listOf(
                visibleFrame(206, "c1", listOf(imeWindow(bounds = mismatchedBounds))),
                visibleFrame(207, "c2", listOf(imeWindow(bounds = mismatchedBounds))),
            ),
        )
        assertEquals(listOf("ime_target_editor_unbound"), mismatch.reasonCodes)

        val hiddenWithWindow = TabletLayoutProbe.assemble(
            context(),
            listOf(
                normalFrame(208, "c1").copy(
                    interactiveWindows = normalFrame(208, "c1").interactiveWindows + imeWindow(),
                ),
                normalFrame(209, "c2").copy(
                    interactiveWindows = normalFrame(209, "c2").interactiveWindows + imeWindow(),
                ),
            ),
        )
        assertEquals(listOf("ime_target_editor_unbound"), hiddenWithWindow.reasonCodes)

        val invalidImeWindowBounds = ProbeRect(0, 1500, 0, 1968)
        val invalidGeometry = TabletLayoutProbe.assemble(
            context(),
            listOf(
                visibleFrame(210, "c1", listOf(imeWindow(bounds = invalidImeWindowBounds))),
                visibleFrame(211, "c2", listOf(imeWindow(bounds = invalidImeWindowBounds))),
            ),
        )
        assertEquals(
            listOf("ime_target_editor_unbound", "region_geometry_invalid", "window_geometry_invalid"),
            invalidGeometry.reasonCodes,
        )

        val nullBoundsImeWindow = imeWindow().copy(bounds = null)
        val unavailableGeometry = TabletLayoutProbe.assemble(
            context(),
            listOf(
                visibleFrame(212, "c1", listOf(nullBoundsImeWindow)),
                visibleFrame(213, "c2", listOf(nullBoundsImeWindow)),
            ),
        )
        assertEquals(
            listOf("ime_target_editor_unbound", "window_geometry_invalid"),
            unavailableGeometry.reasonCodes,
        )

        val lowSystemWindows = (1..14).map { index ->
            window(
                rawId = 68_000_000 + index,
                bounds = ProbeRect(0, 200 + index * 2, 10, 201 + index * 2),
                owner = "com.android.systemui",
                type = "system",
                layer = 0,
                nodes = emptyList(),
            )
        }
        val visibleOverflow = TabletLayoutProbe.assemble(
            context(),
            listOf(
                visibleFrame(214, "c1", lowSystemWindows + imeWindow()),
                visibleFrame(215, "c2", lowSystemWindows + imeWindow()),
            ),
        )
        assertEquals(16, visibleOverflow.frames.first().windows.size)
        assertTrue(visibleOverflow.frames.all { it.windowsTruncated })
        assertFalse(visibleOverflow.frames.first().windows.any { it.type == "input_method" })
        assertEquals(
            listOf("ime_target_editor_unbound", "window_inventory_truncated"),
            visibleOverflow.reasonCodes,
        )
    }

    @Test
    fun invalidOrOversizedCaptureInputsNeverProduceSchemaOutOfRangeFields() {
        assertThrows(IllegalArgumentException::class.java) {
            TabletLayoutProbe.assemble(context(), emptyList())
        }
        assertThrows(IllegalArgumentException::class.java) {
            TabletLayoutProbe.assemble(context(), listOf(normalFrame(200, "c1")))
        }
        assertThrows(IllegalArgumentException::class.java) {
            TabletLayoutProbe.assemble(
                context(),
                listOf(normalFrame(200, "c1").copy(capturedAt = "not-a-time"), normalFrame(201, "c2")),
            )
        }

        assertThrows(IllegalArgumentException::class.java) {
            TabletLayoutProbe.assemble(
                context(),
                listOf(
                    normalFrame(202, "c1"),
                    normalFrame(203, "c2"),
                    normalFrame(204, "c3"),
                    normalFrame(205, "c4"),
                    normalFrame(206, "c5"),
                ),
            )
        }

        val invalidEnvelope = normalFrame(207, "c1").copy(
            captureId = "INVALID CAPTURE",
            captureToken = "bad-token",
            revisionBefore = 0,
            revisionAfter = 0,
            layoutRevision = 0,
            imeRevision = 0,
            interactiveWindows = normalFrame(207, "c1").interactiveWindows.mapIndexed { index, window ->
                if (index == 0) window.copy(layer = Int.MAX_VALUE) else window
            },
        )
        assertThrows(IllegalArgumentException::class.java) {
            TabletLayoutProbe.assemble(context(), listOf(invalidEnvelope, normalFrame(208, "c2")))
        }

        val invalidWindow = window(
            rawId = NAV_ID,
            bounds = ProbeRect(Int.MIN_VALUE, 0, Int.MAX_VALUE, 10),
            displayId = 99,
            layer = 7,
            nodes = emptyList(),
        )
        val invalidFrame = frame(
            209,
            "c1",
            listOf(invalidWindow, window(CHAT_ID, CHAT_BOUNDS, nodes = chatNodes())),
        ).copy(
            display = RawProbeDisplay(99, ProbeSize(-1, 20_000)),
        )
        val secondInvalidFrame = frame(
            210,
            "c2",
            listOf(invalidWindow, window(CHAT_ID, CHAT_BOUNDS, nodes = chatNodes())),
        ).copy(
            display = RawProbeDisplay(99, ProbeSize(-1, 20_000)),
        )
        val result = TabletLayoutProbe.assemble(
            context(),
            listOf(invalidFrame, secondInvalidFrame),
        )
        val first = result.frames.first()
        val unavailable = first.windows.single { it.bounds == null }

        assertEquals(2, result.frames.size)
        assertEquals("c1", first.capture.token)
        assertNull(first.display.displayId)
        assertNull(first.display.effectiveSize)
        assertEquals(7, unavailable.layer)
        assertNull(unavailable.bounds)
        assertNull(unavailable.touchableBounds)
        assertEquals(1, first.panes.size)
        assertFalse(first.windows.any { it.bounds == ProbeRect(0, 0, 0, 0) })
        assertTrue("display_unknown" in result.reasonCodes)
        assertTrue("window_geometry_invalid" in result.reasonCodes)

        val invalidSemanticBounds = ProbeRect(Int.MIN_VALUE, 0, Int.MAX_VALUE, 10)
        val invalidNodeWindows = listOf(
            window(NAV_ID, NAV_BOUNDS, nodes = listOf(node("other", invalidSemanticBounds))),
            window(CHAT_ID, CHAT_BOUNDS, nodes = chatNodes()),
        )
        assertThrows(IllegalArgumentException::class.java) {
            TabletLayoutProbe.assemble(
                context(),
                listOf(frame(211, "c1", invalidNodeWindows), frame(212, "c2", invalidNodeWindows)),
            )
        }
        assertThrows(IllegalArgumentException::class.java) {
            TabletLayoutProbe.assemble(
                context(),
                listOf(
                    normalFrame(213, "c1").copy(
                        ime = RawProbeIme(true, ProbeImeMode.DOCKED, invalidSemanticBounds),
                    ),
                    normalFrame(214, "c2").copy(
                        ime = RawProbeIme(true, ProbeImeMode.DOCKED, invalidSemanticBounds),
                    ),
                ),
            )
        }
    }

    @Test
    fun duplicateRawWindowIdentityIsCollapsedAndBlocked() {
        val duplicate = window(NAV_ID, NAV_BOUNDS, nodes = listOf(listNode()))
        val windows = listOf(duplicate, duplicate, window(CHAT_ID, CHAT_BOUNDS, nodes = chatNodes()))
        val result = TabletLayoutProbe.assemble(
            context(),
            listOf(frame(210, "c1", windows), frame(211, "c2", windows)),
        )

        assertEquals(2, result.frames.first().windows.size)
        assertTrue(result.frames.first().windowsTruncated)
        assertEquals(
            listOf("ime_target_editor_unbound", "window_inventory_truncated"),
            result.reasonCodes,
        )
        assertFalse("window_label_duplicate" in result.reasonCodes)
    }

    @Test
    fun omittedWindowDisplayAndRawGeometryLossUseOnlySerializedTruncationReasons() {
        fun hiddenOverflowFrame(revision: Long, token: String, omittedDisplayId: Int?): RawTabletProbeFrame {
            val base = normalFrame(revision, token)
            val serializedExtras = (1..14).map { index ->
                window(
                    rawId = 69_000_000 + index,
                    bounds = ProbeRect(0, 300 + index * 2, 10, 301 + index * 2),
                    owner = "com.android.systemui",
                    type = "system",
                    layer = 0,
                    nodes = emptyList(),
                )
            }
            val omitted = window(
                rawId = 69_999_999,
                bounds = ProbeRect(0, 1_400, 10, 1_410),
                owner = "com.android.systemui",
                type = "system",
                displayId = omittedDisplayId,
                layer = 0,
                nodes = emptyList(),
            )
            return base.copy(interactiveWindows = base.interactiveWindows + serializedExtras + omitted)
        }

        val omittedDisplay = TabletLayoutProbe.assemble(
            context(),
            listOf(hiddenOverflowFrame(216, "c1", null), hiddenOverflowFrame(217, "c2", 1)),
        )
        assertTrue(omittedDisplay.frames.all { it.windowsTruncated })
        assertEquals(
            listOf("ime_target_editor_unbound", "window_inventory_truncated"),
            omittedDisplay.reasonCodes,
        )
        assertFalse("display_unknown" in omittedDisplay.reasonCodes)
        assertFalse("multi_display_blocked" in omittedDisplay.reasonCodes)

        fun serializedUnknownDisplayFrame(revision: Long, token: String): RawTabletProbeFrame {
            val base = normalFrame(revision, token)
            return base.copy(
                interactiveWindows = base.interactiveWindows.map { window ->
                    if (window.rawWindowId == NAV_ID) window.copy(displayId = null) else window
                },
            )
        }
        val serializedUnknownDisplay = TabletLayoutProbe.assemble(
            context(),
            listOf(
                serializedUnknownDisplayFrame(217, "c1"),
                serializedUnknownDisplayFrame(218, "c2"),
            ),
        )
        assertEquals(listOf("multi_display_blocked"), serializedUnknownDisplay.reasonCodes)
        assertFalse("display_unknown" in serializedUnknownDisplay.reasonCodes)

        fun geometryFrame(
            revision: Long,
            token: String,
            touchableBounds: ProbeRect?,
            geometryInvalid: Boolean,
            readErrors: Int,
        ): RawTabletProbeFrame {
            val base = normalFrame(revision, token)
            return base.copy(
                interactiveWindows = base.interactiveWindows.map { window ->
                    if (window.rawWindowId == NAV_ID) {
                        window.copy(
                            touchableBounds = touchableBounds,
                            geometryInvalid = geometryInvalid,
                        )
                    } else {
                        window
                    }
                },
                readErrors = readErrors,
            )
        }

        val geometryLoss = TabletLayoutProbe.assemble(
            context(),
            listOf(
                geometryFrame(218, "c1", null, geometryInvalid = true, readErrors = 0),
                geometryFrame(
                    219,
                    "c2",
                    ProbeRect(Int.MIN_VALUE, 0, Int.MAX_VALUE, 10),
                    geometryInvalid = false,
                    readErrors = 0,
                ),
                geometryFrame(220, "c3", null, geometryInvalid = false, readErrors = 1),
            ),
        )
        assertTrue(geometryLoss.frames.all { it.windowsTruncated })
        assertTrue(geometryLoss.frames.all { frame ->
            frame.windows.single { it.windowLabel == "aw1" }.touchableBounds == null
        })
        assertEquals(
            listOf("ime_target_editor_unbound", "window_inventory_truncated"),
            geometryLoss.reasonCodes,
        )
        assertFalse("window_geometry_invalid" in geometryLoss.reasonCodes)
    }

    @Test
    fun nonTitleDegenerateNodeDoesNotClaimTitleGeometryFailure() {
        val degenerate = node("other", ProbeRect(20, 300, 20, 320))
        val windows = listOf(
            window(NAV_ID, NAV_BOUNDS, nodes = listOf(listNode(), degenerate)),
            window(CHAT_ID, CHAT_BOUNDS, nodes = chatNodes()),
        )
        val result = TabletLayoutProbe.assemble(
            context(),
            listOf(frame(221, "c1", windows), frame(222, "c2", windows)),
        )

        assertEquals(listOf("node_binding_invalid"), result.reasonCodes)
        assertFalse("title_geometry_invalid" in result.reasonCodes)
    }

    @Test
    fun missingOrAmbiguousCandidatesUseOnlyReasonsRecomputableFromThoseArrays() {
        val conversationMarker = node(
            role = "other",
            bounds = INPUT_BOUNDS,
            editable = true,
        )
        val emptyCandidateWindows = listOf(
            window(NAV_ID, NAV_BOUNDS, nodes = listOf(listNode())),
            window(CHAT_ID, CHAT_BOUNDS, nodes = listOf(conversationMarker)),
        )
        val missing = TabletLayoutProbe.assemble(
            context(),
            listOf(
                frame(223, "c1", emptyCandidateWindows),
                frame(224, "c2", emptyCandidateWindows),
            ),
        )
        assertEquals(
            listOf("region_candidate_missing", "target_title_not_unique"),
            missing.reasonCodes,
        )
        assertFalse("title_wrong_role" in missing.reasonCodes)
        assertFalse("region_geometry_invalid" in missing.reasonCodes)
        assertFalse("region_binding_invalid" in missing.reasonCodes)
        assertFalse("cross_window_region" in missing.reasonCodes)

        val duplicateCorrectTitles = listOf(
            window(NAV_ID, NAV_BOUNDS, nodes = listOf(listNode())),
            window(
                CHAT_ID,
                CHAT_BOUNDS,
                nodes = listOf(
                    toolbarContainerNode(),
                    titleNode(),
                    titleNode(),
                    chatMessageNode(),
                    inputNode(),
                ),
            ),
        )
        val ambiguous = TabletLayoutProbe.assemble(
            context(),
            listOf(
                frame(225, "c1", duplicateCorrectTitles),
                frame(226, "c2", duplicateCorrectTitles),
            ),
        )
        assertEquals(
            listOf("region_candidate_ambiguous", "target_title_not_unique"),
            ambiguous.reasonCodes,
        )
        assertTrue(ambiguous.frames.first().target.titleCandidates.all {
            it.semanticRole == "pane_toolbar_title"
        })
        assertFalse("title_wrong_role" in ambiguous.reasonCodes)
        assertFalse("region_geometry_invalid" in ambiguous.reasonCodes)
    }

    @Test
    fun degenerateRegionsAndOverlaysNeverCreateFalseOcclusion() {
        val degenerateMessage = ProbeRect(1400, 900, 2800, 900)
        val narrowOverlay = window(
            rawId = 70_000_001,
            bounds = ProbeRect(1500, 899, 1600, 901),
            owner = "dev.magina.gateway",
            type = "accessibility_overlay",
            layer = 20,
            nodes = emptyList(),
        )
        val degenerateRegionWindows = listOf(
            window(NAV_ID, NAV_BOUNDS, nodes = listOf(listNode())),
            window(
                CHAT_ID,
                CHAT_BOUNDS,
                nodes = listOf(
                    toolbarContainerNode(), titleNode(), chatMessageNode(degenerateMessage), inputNode(),
                ),
            ),
            narrowOverlay,
        )
        val degenerateRegion = TabletLayoutProbe.assemble(
            context(),
            listOf(
                frame(227, "c1", degenerateRegionWindows),
                frame(228, "c2", degenerateRegionWindows),
            ),
        )
        assertEquals(
            listOf("node_binding_invalid", "region_binding_invalid", "region_geometry_invalid"),
            degenerateRegion.reasonCodes,
        )
        assertFalse("overlay_target_occlusion" in degenerateRegion.reasonCodes)

        val degenerateOverlay = window(
            rawId = 70_000_002,
            bounds = ProbeRect(1500, 900, 1500, 901),
            owner = "dev.magina.gateway",
            type = "accessibility_overlay",
            layer = 20,
            nodes = emptyList(),
        )
        val overlayWindows = normalFrame(229, "c1").interactiveWindows + degenerateOverlay
        val invalidOverlay = TabletLayoutProbe.assemble(
            context(),
            listOf(frame(229, "c1", overlayWindows), frame(230, "c2", overlayWindows)),
        )
        assertEquals(listOf("window_geometry_invalid"), invalidOverlay.reasonCodes)
        assertFalse("overlay_target_occlusion" in invalidOverlay.reasonCodes)
    }

    @Test
    fun intervalAndCaptureSpanUseTheStrictRunnerBounds() {
        val start = TEST_TIME.plusSeconds(220)
        val tooFast = TabletLayoutProbe.assemble(
            context(),
            listOf(
                normalFrame(220, "c1").copy(capturedAt = TEST_TIME_FORMATTER.format(start)),
                normalFrame(221, "c2").copy(capturedAt = TEST_TIME_FORMATTER.format(start.plusMillis(899))),
            ),
        )
        assertTrue("capture_order_invalid" in tooFast.reasonCodes)
        assertEquals(899, tooFast.consistency.minimumIntervalMs)

        val tooLong = TabletLayoutProbe.assemble(
            context(),
            listOf(
                normalFrame(222, "c1").copy(capturedAt = TEST_TIME_FORMATTER.format(start)),
                normalFrame(223, "c2").copy(capturedAt = TEST_TIME_FORMATTER.format(start.plusSeconds(16))),
            ),
        )
        assertTrue("capture_span_exceeded" in tooLong.reasonCodes)
        assertTrue("capture_span_exceeded" in tooLong.consistency.reasonCodes)

        val oneTickTooLong = TabletLayoutProbe.assemble(
            context(),
            listOf(
                normalFrame(224, "c1").copy(capturedAt = TEST_TIME_FORMATTER.format(start)),
                normalFrame(225, "c2").copy(
                    capturedAt = TEST_TIME_FORMATTER.format(start.plusSeconds(15).plusNanos(100)),
                ),
            ),
        )
        assertEquals(listOf("capture_span_exceeded"), oneTickTooLong.reasonCodes)
        assertEquals(15_000, oneTickTooLong.consistency.minimumIntervalMs)
        assertEquals(listOf("capture_span_exceeded"), oneTickTooLong.consistency.reasonCodes)
    }

    @Test
    fun intrinsicUpstreamProvenanceReasonsDoNotDependOnValidationTime() {
        val frames = listOf(normalFrame(240, "c1"), normalFrame(241, "c2"))
        val positive = TabletLayoutProbe.assemble(context(), frames)
        assertEquals("observed", positive.diagnosticStatus)
        assertTrue(positive.reasonCodes.isEmpty())
        assertFalse(
            TabletProbeRunContext::class.java.declaredFields.any {
                it.name.contains("validationNow", ignoreCase = true)
            },
        )

        val staleT0 = TabletLayoutProbe.assemble(
            context(actualT0CapturedAt = TEST_TIME_FORMATTER.format(TEST_TIME.minusSeconds(601))),
            frames,
        )
        assertEquals(listOf("upstream_t0_stale"), staleT0.reasonCodes)
        assertTrue(staleT0.consistency.stable)

        val hashMismatch = TabletLayoutProbe.assemble(
            context(declaredT0ArtifactHash = HASH_B),
            frames,
        )
        assertEquals(listOf("upstream_t0_hash_mismatch"), hashMismatch.reasonCodes)

        val producerMismatch = TabletLayoutProbe.assemble(
            context(declaredT0ProducerSha = SHA_B),
            frames,
        )
        assertEquals(listOf("upstream_t0_producer_mismatch"), producerMismatch.reasonCodes)

        val deviceMismatch = TabletLayoutProbe.assemble(
            context(declaredDeviceProfileHash = HASH_C),
            frames,
        )
        assertEquals(listOf("upstream_t0_device_hash_mismatch"), deviceMismatch.reasonCodes)

        val identityMismatch = TabletLayoutProbe.assemble(
            context(actualT0RunId = "different-t0-run", declaredT0RunId = "t0-test"),
            frames,
        )
        assertEquals(listOf("upstream_t0_invalid"), identityMismatch.reasonCodes)
    }

    @Test
    fun invalidRunnerOwnedContextIsRejectedBeforeJsonConstruction() {
        assertThrows(IllegalArgumentException::class.java) {
            TabletLayoutProbe.assemble(
                context(runId = "PRIVATE RUN ID"),
                listOf(normalFrame(230, "c1"), normalFrame(231, "c2")),
            )
        }
        assertThrows(IllegalArgumentException::class.java) {
            context(readinessReasons = List(65) { index -> "reason_$index" })
        }
        assertThrows(IllegalArgumentException::class.java) {
            context(p0UnsupportedReasons = listOf("wechat_layout_unverified"))
        }
    }

    @Test
    fun rawT0UsesStrictUtf8Rfc8259AndTheFrozenPowerShellCanonicalHashVector() {
        val malformedUtf8 = byteArrayOf(
            0x7b, 0x22, 0x61, 0x22, 0x3a, 0x22,
            0xc3.toByte(), 0x28,
            0x22, 0x7d,
        )
        val bomObject = byteArrayOf(0xef.toByte(), 0xbb.toByte(), 0xbf.toByte()) +
            "{}".toByteArray(Charsets.UTF_8)
        val tooDeep = ("{\"a\":".repeat(65) + "0" + "}".repeat(65)).toByteArray(Charsets.UTF_8)
        val rejected = listOf(
            "{\"a\":1,}",
            "{'a':1}",
            "{\"a\":1,\"a\":2}",
            "{\"a\":1.0}",
            "{\"a\":9223372036854775808}",
            "{\"a\":00}",
            "{\"a\":-01}",
            "{\"a\":1２}",
            "{\"a\":-1٢}",
            "{\"a\":\"\\u００８５\"}",
            "{\"a\":\"\\u٠٠٨٥\"}",
            "[1,2]",
        ).map { it.toByteArray(Charsets.UTF_8) } + listOf(malformedUtf8, bomObject, tooDeep)
        rejected.forEach { raw ->
            assertThrows(IllegalArgumentException::class.java) {
                context(upstreamT0RawUtf8 = raw, declaredDeviceProfileHash = HASH_C)
            }
        }

        assertEquals(
            "{\"a\":0}",
            canonicalProbeJson(parseStrictProbeJson("{\"a\":-0}".toByteArray(Charsets.UTF_8))),
        )
        assertEquals(
            "{\"a\":\"Aé\"}",
            canonicalProbeJson(
                parseStrictProbeJson("{\"a\":\"\\u0041\\u00E9\"}".toByteArray(Charsets.UTF_8)),
            ),
        )

        val vector = """
            {
              "z": null,
              "script": "</script>",
              "unicode": "é汉",
              "separator": "\u2028\u2029",
              "control": "line\n\t\"\\\\",
              "arr": [1, 9223372036854775807, -9223372036854775808],
              "nested": {"b": false, "a": true}
            }
        """.trimIndent().toByteArray(Charsets.UTF_8)
        val parsedVector = parseStrictProbeJson(vector)
        assertEquals(
            """{"arr":[1,9223372036854775807,-9223372036854775808],"control":"line\n\t\"\\\\","nested":{"a":true,"b":false},"script":"</script>","separator":"\u2028\u2029","unicode":"é汉","z":null}""",
            canonicalProbeJson(parsedVector),
        )
        assertEquals(
            "sha256:245479179d19f572c312b749bd8dab078d9f53d0d0e3ffef3a1d7f3251aa30cb",
            probeDeviceProfileHash(parsedVector),
        )

        val specialControls = parseStrictProbeJson(
            """{"controls":"\b\f\r\u0001","nel":"\u0085"}""".toByteArray(Charsets.UTF_8),
        )
        assertEquals(
            """{"controls":"\b\f\r\u0001","nel":"\u0085"}""",
            canonicalProbeJson(specialControls),
        )
    }

    @Test
    fun oversizedTitleCharSequenceIsRejectedBeforeMaterializationOrHashing() {
        val explosive = object : CharSequence {
            override val length: Int = Int.MAX_VALUE
            override fun get(index: Int): Char = error("must not inspect oversized content")
            override fun subSequence(startIndex: Int, endIndex: Int): CharSequence =
                error("must not slice oversized content")
            override fun toString(): String = error("must not materialize oversized content")
        }

        assertEquals(
            ProbeTitleContentMatch.OVER_BUDGET,
            probeMatchesExpectedTitle(explosive, EXPECTED_TITLE_HASH),
        )
    }

    @Test
    fun adapterStringBudgetsRejectBeforeMaterializationAndRemainFailClosed() {
        val explosive = object : CharSequence {
            override val length: Int = Int.MAX_VALUE
            override fun get(index: Int): Char = error("must not inspect oversized adapter text")
            override fun subSequence(startIndex: Int, endIndex: Int): CharSequence =
                error("must not slice oversized adapter text")
            override fun toString(): String = error("must not materialize oversized adapter text")
        }

        assertThrows(IllegalArgumentException::class.java) {
            probeMaterializeBoundedText(explosive, MAX_A11Y_CLASS_NAME_CHARACTERS)
        }
        assertThrows(IllegalArgumentException::class.java) {
            probeSafePackageName(explosive)
        }
        val boundaryClass = "x".repeat(MAX_A11Y_CLASS_NAME_CHARACTERS)
        assertEquals(
            boundaryClass,
            probeMaterializeBoundedText(boundaryClass, MAX_A11Y_CLASS_NAME_CHARACTERS),
        )
        assertEquals("com.tencent.mm", probeSafePackageName("com.tencent.mm"))
        assertNull(probeSafePackageName("not a package"))

        val boundaryMaterial = "m".repeat(MAX_STRUCTURAL_FINGERPRINT_MATERIAL_CHARACTERS)
        assertEquals(boundaryMaterial, probeRequireBoundedStructuralMaterial(boundaryMaterial))
        assertThrows(IllegalArgumentException::class.java) {
            probeRequireBoundedStructuralMaterial(
                "m".repeat(MAX_STRUCTURAL_FINGERPRINT_MATERIAL_CHARACTERS + 1),
            )
        }

        val truncated = TabletLayoutProbe.assemble(
            context(),
            listOf(
                normalFrame(250, "c1").copy(nodesTruncated = true),
                normalFrame(251, "c2").copy(nodesTruncated = true),
            ),
        )
        assertEquals(listOf("node_inventory_truncated"), truncated.reasonCodes)
        assertTrue(truncated.frames.all { it.nodesTruncated })
    }

    private fun context(
        saltByte: Byte = 7,
        runSalt: ByteArray? = null,
        expectedTitleHash: String = EXPECTED_TITLE_HASH,
        runId: String = "tl1-v2-test",
        actualT0RunId: String = "t0-test",
        declaredT0RunId: String = actualT0RunId,
        actualT0CapturedAt: String = TEST_TIME_FORMATTER.format(TEST_TIME),
        declaredT0CapturedAt: String = actualT0CapturedAt,
        declaredT0ArtifactHash: String? = null,
        declaredT0ProducerSha: String = TRUSTED_T0_PRODUCER_SHA,
        declaredDeviceProfileHash: String? = null,
        upstreamT0RawUtf8: ByteArray? = null,
        readinessReasons: List<String> = listOf("native_multi_window"),
        p0UnsupportedReasons: List<String> = listOf(
            "wechat_layout_unverified",
            "tablet_landscape_p0_unimplemented",
        ),
    ): TabletProbeRunContext {
        val device = JSONObject()
            .put("serial_hash", HASH_D)
            .put("manufacturer", "vivo")
            .put("model", "pa2553")
            .put("api_level", 36)
            .put("fingerprint_hash", HASH_E)
        val generatedUpstreamRaw = JSONObject()
            .put("schema_version", 5)
            .put("run_id", actualT0RunId)
            .put("captured_at_utc", actualT0CapturedAt)
            .put("device", device)
            .put(
                "assessment",
                JSONObject()
                    .put("intake_status", "accepted")
                    .put("readiness_status", "blocked")
                    .put("readiness_block_reasons", JSONArray(readinessReasons))
                    .put("p0_capability", "unsupported")
                    .put("p0_unsupported_reasons", JSONArray(p0UnsupportedReasons)),
            )
            .toString()
            .toByteArray(Charsets.UTF_8)
        val upstreamRaw = upstreamT0RawUtf8 ?: generatedUpstreamRaw
        return TabletProbeRunContext(
            runId = runId,
            expectedTitleHash = expectedTitleHash,
            runSalt = runSalt ?: ByteArray(32) { saltByte },
            upstreamT0RawUtf8 = upstreamRaw,
            provenance = TabletProbeProvenance(
                kind = "offline_fixture",
                name = "tablet_probe_test",
                version = "v2",
                producerCommitSha = SHA_A,
                producerArtifactSha256 = HASH_A,
            ),
            upstreamT0 = TabletProbeUpstreamT0(
                sourceKind = "offline_fixture",
                runId = declaredT0RunId,
                capturedAt = declaredT0CapturedAt,
                artifactSha256 = declaredT0ArtifactHash ?: probeSha256Bytes(upstreamRaw),
                producerCommitSha = declaredT0ProducerSha,
                deviceProfileHash = declaredDeviceProfileHash ?: probeDeviceProfileHash(
                    parseStrictProbeJson(upstreamRaw).members.getValue("device")
                        as StrictProbeJsonValue.ObjectValue,
                ),
                readinessReasons = readinessReasons,
                p0UnsupportedReasons = p0UnsupportedReasons,
            ),
        )
    }

    private fun normalFrame(
        revision: Long,
        token: String,
        inputFocused: Boolean = false,
        windowFocused: Boolean = false,
    ): RawTabletProbeFrame = frame(
        revision = revision,
        token = token,
        windows = listOf(
            window(rawId = NAV_ID, bounds = NAV_BOUNDS, nodes = listOf(listNode())),
            window(
                rawId = CHAT_ID,
                bounds = CHAT_BOUNDS,
                focused = windowFocused,
                nodes = chatNodes(inputFocused),
            ),
        ),
    )

    private fun frame(
        revision: Long,
        token: String,
        windows: List<RawTabletWindow>,
        captureExpectedTitleHash: String? = EXPECTED_TITLE_HASH,
    ): RawTabletProbeFrame = RawTabletProbeFrame(
        captureId = "capture-$token",
        capturedAt = TEST_TIME_FORMATTER.format(
            TEST_TIME.plusSeconds(token.removePrefix("c").toLongOrNull()?.minus(1) ?: 0),
        ),
        captureToken = token,
        captureExpectedTitleHash = captureExpectedTitleHash,
        revisionBefore = revision,
        revisionAfter = revision,
        layoutRevision = revision,
        imeRevision = revision,
        display = RawProbeDisplay(0, ProbeSize(2800, 1968)),
        interactiveWindows = windows,
        ime = RawProbeIme(false, ProbeImeMode.NONE, null),
        nodesTruncated = false,
        readErrors = 0,
    )

    private fun window(
        rawId: Int,
        bounds: ProbeRect,
        owner: String = WECHAT_PACKAGE,
        focused: Boolean = false,
        type: String = "application",
        displayId: Int? = 0,
        layer: Int = if (bounds == CHAT_BOUNDS) 2 else 1,
        nodes: List<RawTabletNode>,
    ): RawTabletWindow = RawTabletWindow(
        rawWindowId = rawId,
        displayId = displayId,
        type = type,
        rootPackage = owner,
        layer = layer,
        bounds = bounds,
        touchableBounds = bounds,
        rootStatus = ProbeRootStatus.READABLE,
        active = focused,
        focused = focused,
        nodes = nodes,
    )

    private fun titleNode(bounds: ProbeRect = CHAT_TITLE_BOUNDS): RawTabletNode = node(
        role = "other",
        bounds = bounds,
        ancestorBounds = listOf(
            if (bounds == NAV_TITLE_BOUNDS) NAV_TOOLBAR_BOUNDS else CHAT_TOOLBAR_BOUNDS,
        ),
        toolbarAncestorBounds = if (bounds == CHAT_TITLE_BOUNDS) listOf(CHAT_TOOLBAR_BOUNDS) else emptyList(),
        hashes = setOf(EXPECTED_TITLE_HASH),
    )

    private fun toolbarContainerNode(): RawTabletNode = node(
        role = "container",
        bounds = CHAT_TOOLBAR_BOUNDS,
    )

    private fun chatMessageNode(bounds: ProbeRect = CHAT_MESSAGE_BOUNDS): RawTabletNode = node(
        role = "message_viewport",
        bounds = bounds,
        scrollable = true,
    )

    private fun chatNodes(inputFocused: Boolean = false): List<RawTabletNode> = listOf(
        toolbarContainerNode(),
        titleNode(),
        chatMessageNode(),
        inputNode(focused = inputFocused),
    )

    private fun inputNode(
        focused: Boolean = false,
        bounds: ProbeRect = INPUT_BOUNDS,
    ): RawTabletNode = node(
        role = "input_editor",
        bounds = bounds,
        editable = true,
        focused = focused,
        structural = "android.widget.EditText|chat_input|1400|1820|2800|1968",
    )

    private fun listNode(): RawTabletNode = node(
        role = "message_viewport",
        bounds = NAV_LIST_BOUNDS,
        scrollable = true,
    )

    private fun node(
        role: String,
        bounds: ProbeRect,
        ancestorBounds: List<ProbeRect> = emptyList(),
        toolbarAncestorBounds: List<ProbeRect> = emptyList(),
        editable: Boolean = false,
        scrollable: Boolean = false,
        focused: Boolean = false,
        hashes: Set<String> = emptySet(),
        structural: String = "$role|$bounds",
    ): RawTabletNode = RawTabletNode(
        nodePackage = WECHAT_PACKAGE,
        role = role,
        bounds = bounds,
        ancestorBounds = ancestorBounds,
        toolbarAncestorBounds = toolbarAncestorBounds,
        visible = true,
        enabled = true,
        clickable = editable,
        longClickable = false,
        editable = editable,
        scrollable = scrollable,
        checkable = false,
        focused = focused,
        matchesExpectedTitle = EXPECTED_TITLE_HASH in hashes,
        structuralFingerprintMaterial = structural,
    )

    private fun collectKeys(value: Any?, keys: MutableSet<String>) {
        when (value) {
            is JSONObject -> for (key in value.keys()) {
                keys += key
                collectKeys(value.get(key), keys)
            }
            is JSONArray -> for (index in 0 until value.length()) collectKeys(value.get(index), keys)
        }
    }

    private fun keysOf(value: JSONObject): Set<String> = buildSet {
        for (key in value.keys()) add(key)
    }

    private companion object {
        const val NAV_ID = 81_234_567
        const val CHAT_ID = 91_234_567
        const val REPLACEMENT_NAV_ID = 71_234_567
        const val SHA_A = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        const val SHA_B = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        const val HASH_A = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        const val HASH_B = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        const val HASH_C = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
        const val HASH_D = "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
        const val HASH_E = "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
        val TEST_TIME: Instant = Instant.parse("2026-08-25T00:00:00Z")
        val TEST_TIME_FORMATTER = DateTimeFormatterBuilder().appendInstant(7).toFormatter()
        val EXPECTED_TITLE_HASH = probeContentHash("文件传输助手")
        val NAV_BOUNDS = ProbeRect(0, 0, 1400, 1968)
        val CHAT_BOUNDS = ProbeRect(1400, 0, 2800, 1968)
        val NAV_TOOLBAR_BOUNDS = ProbeRect(0, 0, 1400, 180)
        val CHAT_TOOLBAR_BOUNDS = ProbeRect(1400, 0, 2800, 180)
        val NAV_TITLE_BOUNDS = ProbeRect(40, 40, 400, 120)
        val CHAT_TITLE_BOUNDS = ProbeRect(1460, 40, 1860, 120)
        val NAV_LIST_BOUNDS = ProbeRect(0, 180, 1400, 1968)
        val CHAT_MESSAGE_BOUNDS = ProbeRect(1400, 180, 2800, 1800)
        val INPUT_BOUNDS = ProbeRect(1400, 1800, 2800, 1968)
        val IME_BOUNDS = ProbeRect(0, 1500, 2800, 1968)
    }
}
