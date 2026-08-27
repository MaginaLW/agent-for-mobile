package dev.magina.gateway.tablet

import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import java.text.Normalizer
import java.time.Duration
import java.time.Instant
import java.util.Collections

internal const val WECHAT_PACKAGE = "com.tencent.mm"

private const val MAX_WINDOWS = 16
private const val MAX_PANES = 8
private const val MAX_NODES = 512
private const val MAX_FRAMES = 4
private const val MAX_INTERVAL_MS = 60_000L
private const val MIN_INTERVAL_MS = 900L
private val MAX_CAPTURE_SPAN: Duration = Duration.ofSeconds(15)
private val MAX_T0_AGE: Duration = Duration.ofMinutes(10)
internal const val TRUSTED_T0_PRODUCER_SHA = "4ca32b131007df58f7752c5ee9b2d049cb1cd54e"
internal const val MAX_TITLE_HASH_CHARACTERS = 256

/**
 * 纯 Kotlin run assembler。raw a11y window id 仅用于本次双帧 awN 映射，输出没有 raw/stable
 * window identity，也没有动作能力。无法安全表达的 0/1 帧与非法时间会在构造边界显式拒绝。
 */
internal object TabletLayoutProbe {

    fun assemble(
        context: TabletProbeRunContext,
        rawFrames: List<RawTabletProbeFrame>,
    ): TabletLayoutObservation {
        requireValidContext(context)
        require(rawFrames.size in 2..MAX_FRAMES) { "tablet probe requires two to four frames" }
        require(rawFrames.all { frame ->
            frame.captureExpectedTitleHash?.let(::isStrictProbeHash) == true &&
                frame.captureExpectedTitleHash == context.expectedTitleHash
        }) { "capture-time expected title hash is missing, invalid, or does not match the run context" }
        val selectedFrames = rawFrames
        require(selectedFrames.all { isCanonicalProbeTimestamp(it.capturedAt) }) {
            "tablet probe frame timestamp is not canonical UTC"
        }
        val frameInstants = selectedFrames.map { Instant.parse(it.capturedAt) }
        require(frameInstants.zipWithNext().all { (before, after) ->
            val interval = Duration.between(before, after).toMillis()
            interval in 1..MAX_INTERVAL_MS
        }) { "tablet probe frame interval cannot be represented by the closed consistency schema" }
        require(selectedFrames.withIndex().all { (index, frame) ->
            frame.captureToken == "c${index + 1}" && isSafeProbeId(frame.captureId) &&
                listOf(
                    frame.revisionBefore, frame.revisionAfter, frame.layoutRevision, frame.imeRevision,
                ).all(::validRevision)
        }) { "tablet probe capture identity or revision is outside the closed schema" }
        require(selectedFrames.flatMap { it.interactiveWindows }.all { window ->
            window.type in WINDOW_TYPES && window.layer in -32_768..32_767 &&
                (window.rootPackage == null || isSafeProbeId(window.rootPackage)) &&
                window.nodes.all { node ->
                    node.role in NODE_ROLES && (window.type != "application" ||
                        node.bounds.isSchemaBounded() &&
                        node.ancestorBounds.all { it.isSchemaBounded() } &&
                        node.toolbarAncestorBounds.all { it.isSchemaBounded() })
                }
        }) { "tablet probe raw window or node enum is outside the closed schema" }
        require(selectedFrames.all { frame ->
            (frame.ime.bounds == null || frame.ime.bounds.isSchemaBounded()) &&
                (frame.ime.visible || (frame.ime.mode == ProbeImeMode.NONE && frame.ime.bounds == null))
        }) { "hidden IME raw state is internally inconsistent" }

        val reasons = linkedSetOf<String>()
        addUpstreamT0Reasons(context, frameInstants.first(), reasons)
        val expectedTitleHash = context.expectedTitleHash

        val suppliedSalt = context.copyRunSalt()
        require(suppliedSalt.size == 32) { "tablet probe run salt must contain exactly 32 bytes" }
        // 即使 runner 误复用同一随机盐，不同 run_id 也不会产生可跨 run 关联的 fingerprint。
        val runSalt = deriveRunSalt(suppliedSalt, context.runId)

        val windowLabels = assignRunLocalWindowLabels(selectedFrames)
        val frames = selectedFrames.mapIndexed { index, raw ->
            sanitizeFrame(
                raw = raw,
                frameIndex = index,
                expectedTitleHash = expectedTitleHash,
                runSalt = runSalt,
                labels = windowLabels,
                reasons = reasons,
            )
        }

        val rawAtomic = selectedFrames.all(::isRawAtomic)
        if (!rawAtomic) reasons += "atomic_capture_revision_invalid"
        val revisionsIncreasing = selectedFrames.zipWithNext().all { (before, after) ->
            validRevision(before.revisionBefore) && validRevision(after.revisionBefore) &&
                before.revisionBefore < after.revisionBefore
        }
        if (!revisionsIncreasing) reasons += "capture_order_invalid"

        val identityStable = identitySetStable(frames)
        if (!identityStable) reasons += "window_identity_replacement"
        val targetStable = frames.drop(1).all {
            it.target.conversationWindowLabel == frames.first().target.conversationWindowLabel &&
                it.target.conversationPaneLabel == frames.first().target.conversationPaneLabel
        }
        if (!targetStable) reasons += "target_window_pane_drift"
        val semanticStable = frames.drop(1).all { semanticSignature(it) == semanticSignature(frames.first()) }
        if (!semanticStable) reasons += "capture_semantics_drift"

        val intervalMs = minimumIntervalMs(selectedFrames)
        val captureSpanExceeded = captureSpan(selectedFrames) > MAX_CAPTURE_SPAN
        if (intervalMs < MIN_INTERVAL_MS) reasons += "capture_order_invalid"
        if (captureSpanExceeded) reasons += "capture_span_exceeded"

        val consistencyReasons = linkedSetOf<String>()
        if (!rawAtomic) consistencyReasons += "atomic_capture_revision_invalid"
        if (!revisionsIncreasing || intervalMs < MIN_INTERVAL_MS) {
            consistencyReasons += "capture_order_invalid"
        }
        if (captureSpanExceeded) {
            consistencyReasons += "capture_span_exceeded"
        }
        if (!identityStable) consistencyReasons += "window_identity_replacement"
        if (!targetStable) consistencyReasons += "target_window_pane_drift"
        if (!semanticStable) consistencyReasons += "capture_semantics_drift"

        val reasonList = reasons.toList().sorted()
        return TabletLayoutObservation(
            runId = context.runId,
            capturedAt = selectedFrames.last().capturedAt,
            provenance = context.provenance,
            upstreamT0 = context.upstreamT0,
            frames = frames,
            consistency = ProbeConsistency(
                sampleCount = selectedFrames.size,
                minimumIntervalMs = intervalMs.coerceIn(0, MAX_INTERVAL_MS),
                stable = consistencyReasons.isEmpty(),
                reasonCodes = consistencyReasons.toList().sorted(),
            ),
            diagnosticStatus = if (reasonList.isEmpty()) "observed" else "blocked",
            reasonCodes = reasonList,
        )
    }

    private fun sanitizeFrame(
        raw: RawTabletProbeFrame,
        frameIndex: Int,
        expectedTitleHash: String,
        runSalt: ByteArray,
        labels: Map<Int, String>,
        reasons: MutableSet<String>,
    ): TabletProbeFrame {
        val canonicalToken = "c${frameIndex + 1}"
        val capture = ProbeCapture(
            token = canonicalToken,
            revisionBefore = raw.revisionBefore,
            revisionAfter = raw.revisionAfter,
            layoutRevision = raw.layoutRevision,
            imeRevision = raw.imeRevision,
        )
        val duplicateRawId = raw.interactiveWindows.groupingBy { it.rawWindowId }.eachCount().any { it.value > 1 }
        val uniqueRawWindows = raw.interactiveWindows.distinctBy { it.rawWindowId }
        val rawWindowInventoryLoss = raw.readErrors > 0 || uniqueRawWindows.any { window ->
            window.geometryInvalid ||
                window.bounds?.isSchemaBounded() == false ||
                window.touchableBounds?.isSchemaBounded() == false
        }
        val windowsTruncated = raw.windowsTruncated || rawWindowInventoryLoss ||
            duplicateRawId || uniqueRawWindows.size > MAX_WINDOWS
        if (windowsTruncated) reasons += "window_inventory_truncated"

        val serializedRawWindows = selectRawWindows(raw)
        val windows = serializedRawWindows.map { sanitizeWindow(it, labels.getValue(it.rawWindowId), reasons) }

        val serializedApplicationWindows = serializedRawWindows.filter { it.type == "application" }
        if (serializedApplicationWindows.size != 2) reasons += "window_count_not_two"

        val displayId = raw.display.displayId?.takeIf { it in 0..16 }
        val displaySize = raw.display.effectiveSize?.takeIf(::validSize)
        if (displayId == null || displaySize == null) {
            reasons += "display_unknown"
        }
        if (displayId != null && windows.any { it.displayId != displayId }) reasons += "multi_display_blocked"
        if (displaySize == null || displaySize.width <= displaySize.height) reasons += "not_landscape"

        val paneApplicationWindows = serializedApplicationWindows.filter { window ->
            window.bounds?.isSchemaBounded() == true
        }
        val allPanes = paneApplicationWindows.map { window ->
            val windowLabel = labels.getValue(window.rawWindowId)
            val binding = if (window.rootStatus == ProbeRootStatus.READABLE) {
                ProbePaneBinding.ROOT_SUBTREE
            } else {
                reasons += "pane_geometry_invalid"
                ProbePaneBinding.UNKNOWN
            }
            ProbePane(
                paneLabel = paneLabel(windowLabel),
                windowLabel = windowLabel,
                role = candidatePaneRole(window),
                bounds = sanitizeRect(requireNotNull(window.bounds), "pane_geometry_invalid", reasons),
                binding = binding,
            )
        }
        val panesTruncated = allPanes.size > MAX_PANES
        if (panesTruncated) reasons += "pane_inventory_truncated"
        val panes = allPanes.take(MAX_PANES)
        val paneByWindowLabel = panes.associateBy { it.windowLabel }
        if (panes.size != 2 || serializedApplicationWindows.size != panes.size ||
            panes.count { it.role == ProbePaneRole.NAVIGATION } != 1 ||
            panes.count { it.role == ProbePaneRole.CONVERSATION } != 1
        ) reasons += "window_pane_bijection_invalid"

        val conversationRawIds = paneApplicationWindows
            .filter { it.rootPackage == WECHAT_PACKAGE && candidatePaneRole(it) == ProbePaneRole.CONVERSATION }
            .map { it.rawWindowId }
        val conversationRawId = conversationRawIds.singleOrNull()
        val conversationWindowLabel = conversationRawId?.let(labels::getValue)
            ?.takeIf(paneByWindowLabel::containsKey)
        val conversationPaneLabel = conversationWindowLabel?.let { paneByWindowLabel.getValue(it).paneLabel }
        if (conversationWindowLabel == null || conversationPaneLabel == null) {
            reasons += "target_window_pane_missing"
        }

        val nodes = mutableListOf<ProbeNodeObservation>()
        val titleCandidates = mutableListOf<ProbeTitleCandidate>()
        val toolbarCandidates = mutableListOf<ProbeRegionCandidate>()
        val messageCandidates = mutableListOf<ProbeRegionCandidate>()
        val inputCandidates = mutableListOf<ProbeInputCandidate>()
        var nodesTruncated = raw.nodesTruncated

        for (window in paneApplicationWindows) {
            val windowLabel = labels.getValue(window.rawWindowId)
            val pane = paneByWindowLabel[windowLabel] ?: continue
            val windowBounds = requireNotNull(windows.single { it.windowLabel == windowLabel }.bounds)
            for (node in window.nodes) {
                if (nodes.size >= MAX_NODES) {
                    nodesTruncated = true
                    break
                }
                val nodeLabel = "an${nodes.size + 1}"
                val nodeBounds = sanitizeRect(node.bounds, "node_binding_invalid", reasons)
                if (!windowBounds.contains(nodeBounds)) reasons += "node_binding_invalid"
                val canEmitTitleCandidate = node.matchesExpectedTitle && titleCandidates.size < 32
                val toolbarBounds = if (canEmitTitleCandidate) {
                    toolbarCandidateBounds(node, windowBounds, reasons)
                } else {
                    nodeBounds
                }
                val toolbarContainer = nodes.lastOrNull { observation ->
                    observation.windowLabel == windowLabel &&
                        observation.paneLabel == pane.paneLabel &&
                        observation.role == "container" &&
                        observation.bounds == toolbarBounds
                }
                val provenToolbarTitle = canEmitTitleCandidate &&
                    conversationRawId == window.rawWindowId &&
                    toolbarContainer != null &&
                    provesToolbarTitle(node, nodeBounds, toolbarBounds, windowBounds)
                val nodeRole = if (provenToolbarTitle) "toolbar_title" else sanitizeNodeRole(node.role, reasons)
                nodes += ProbeNodeObservation(
                    nodeLabel = nodeLabel,
                    windowLabel = windowLabel,
                    paneLabel = pane.paneLabel,
                    role = nodeRole,
                    bounds = nodeBounds,
                    visible = node.visible,
                    enabled = node.enabled,
                    clickable = node.clickable,
                    longClickable = node.longClickable,
                    editable = node.editable,
                    scrollable = node.scrollable,
                    checkable = node.checkable,
                    focused = node.focused,
                )

                if (node.matchesExpectedTitle) {
                    if (canEmitTitleCandidate) {
                        titleCandidates += ProbeTitleCandidate(
                            candidateLabel = "tt${titleCandidates.size + 1}",
                            nodeLabel = nodeLabel,
                            labelHash = expectedTitleHash,
                            semanticRole = if (provenToolbarTitle) "pane_toolbar_title" else "unknown",
                            windowLabel = windowLabel,
                            paneLabel = pane.paneLabel,
                            bounds = nodeBounds,
                            captureToken = canonicalToken,
                        )
                    } else {
                        nodesTruncated = true
                    }
                    if (provenToolbarTitle && toolbarCandidates.size < 16) {
                        toolbarCandidates += ProbeRegionCandidate(
                            candidateLabel = "tb${toolbarCandidates.size + 1}",
                            sourceNodeLabels = listOf(toolbarContainer?.nodeLabel ?: nodeLabel),
                            windowLabel = windowLabel,
                            paneLabel = pane.paneLabel,
                            bounds = toolbarBounds,
                            captureToken = canonicalToken,
                        )
                    } else if (provenToolbarTitle) {
                        nodesTruncated = true
                    }
                }
                if (node.visible && node.scrollable && !node.editable && nodeRole == "message_viewport" &&
                    conversationRawId == window.rawWindowId
                ) {
                    if (messageCandidates.size < 16) {
                        messageCandidates += ProbeRegionCandidate(
                            candidateLabel = "msg${messageCandidates.size + 1}",
                            sourceNodeLabels = listOf(nodeLabel),
                            windowLabel = windowLabel,
                            paneLabel = pane.paneLabel,
                            bounds = nodeBounds,
                            captureToken = canonicalToken,
                        )
                    } else {
                        nodesTruncated = true
                    }
                }
                if (node.visible && node.editable && nodeRole == "input_editor" &&
                    node.nodePackage == WECHAT_PACKAGE &&
                    conversationRawId == window.rawWindowId
                ) {
                    if (inputCandidates.size < 16) {
                        inputCandidates += ProbeInputCandidate(
                            candidateLabel = "in${inputCandidates.size + 1}",
                            nodeLabel = nodeLabel,
                            nodePackage = WECHAT_PACKAGE,
                            windowLabel = windowLabel,
                            paneLabel = pane.paneLabel,
                            bounds = nodeBounds,
                            captureToken = canonicalToken,
                            editable = true,
                            focused = node.focused,
                            editorFingerprintHash = probeRunSaltedHash(
                                runSalt,
                                "${window.rawWindowId}:${node.structuralFingerprintMaterial}",
                            ),
                        )
                    } else {
                        nodesTruncated = true
                    }
                }
            }
        }
        if (nodesTruncated) reasons += "node_inventory_truncated"

        if (titleCandidates.size != 1) reasons += "target_title_not_unique"
        if (titleCandidates.any { candidate ->
                candidate.semanticRole != "pane_toolbar_title" ||
                    nodes.singleOrNull { it.nodeLabel == candidate.nodeLabel }?.role != "toolbar_title"
            }
        ) reasons += "title_wrong_role"
        if (toolbarCandidates.isEmpty() || messageCandidates.isEmpty() || inputCandidates.isEmpty()) {
            reasons += "region_candidate_missing"
        }
        if (toolbarCandidates.size > 1 || messageCandidates.size > 1 || inputCandidates.size > 1) {
            reasons += "region_candidate_ambiguous"
        }

        val regionCandidates = toolbarCandidates + messageCandidates + inputCandidates
        if (regionCandidates.any { it.windowLabel != conversationWindowLabel }) reasons += "cross_window_region"
        if (titleCandidates.any { it.windowLabel != conversationWindowLabel }) {
            reasons += "title_wrong_window"
        }
        if (titleCandidates.any { it.paneLabel != conversationPaneLabel }) {
            reasons += "title_wrong_pane"
        }
        val conversationPane = conversationWindowLabel?.let(paneByWindowLabel::get)
        if (titleCandidates.any { title ->
                conversationPane == null || !validRect(title.bounds) ||
                    !conversationPane.bounds.contains(title.bounds)
            }
        ) reasons += "title_geometry_invalid"
        if (regionCandidates.any { candidate ->
                candidate.paneLabel != conversationPaneLabel || conversationPane == null ||
                    !validRect(candidate.bounds) ||
                    !conversationPane.bounds.contains(candidate.bounds)
            }
        ) reasons += "region_binding_invalid"
        if (toolbarCandidates.size == 1 && messageCandidates.size == 1 && inputCandidates.size == 1 &&
            !regionsCloseConversationGeometry(
                conversationPane,
                toolbarCandidates,
                messageCandidates,
                inputCandidates,
            )
        ) reasons += "region_geometry_invalid"

        val focusedWindows = windows.filter { it.focused }
        val focusedApplicationWindows = focusedWindows.filter { it.type == "application" }
        val focusedInputs = inputCandidates.filter { it.focused }
        val focusConflict = focusedWindows.any { it.type != "application" } ||
            focusedWindows.size > 1 || focusedApplicationWindows.size > 1 || focusedInputs.size > 1 ||
            (focusedApplicationWindows.isEmpty() != focusedInputs.isEmpty()) ||
            (focusedApplicationWindows.singleOrNull()?.windowLabel != focusedInputs.singleOrNull()?.windowLabel) ||
            (focusedApplicationWindows.singleOrNull()?.windowLabel?.let { it != conversationWindowLabel } == true)
        if (focusConflict) {
            reasons += "focus_target_conflict"
            reasons += "focus_fallback_insufficient"
        }
        val focusedInput = if (!focusConflict) focusedInputs.singleOrNull() else null
        val focus = when {
            focusConflict -> ProbeFocusObservation("unknown", null, null)
            focusedInput != null -> ProbeFocusObservation("known", focusedInput.windowLabel, focusedInput.candidateLabel)
            else -> ProbeFocusObservation("absent", null, null)
        }

        val rawImeBoundsValid = raw.ime.bounds?.let(::validRect) == true
        val rawImeWindows = uniqueRawWindows.filter { it.type == "input_method" }
        val serializedImeWindows = windows.filter { it.type == "input_method" }
        val serializedImeWindow = serializedImeWindows.singleOrNull()
        val targetWindow = windows.singleOrNull { it.windowLabel == conversationWindowLabel }
        val serializedImeBoundsValid = serializedImeWindow?.bounds?.let(::validRect) == true
        if (serializedImeWindows.any { window -> window.bounds != null && !validRect(window.bounds) } ||
            (raw.ime.visible && raw.ime.bounds != null && !validRect(raw.ime.bounds))
        ) {
            reasons += "region_geometry_invalid"
        }
        val imeInventoryBound = raw.ime.visible && !windowsTruncated && rawImeWindows.size == 1 &&
            serializedImeWindows.size == 1 && displayId != null && targetWindow?.displayId == displayId &&
            serializedImeWindow?.displayId == displayId && rawImeBoundsValid && serializedImeBoundsValid &&
            serializedImeWindow?.bounds == raw.ime.bounds
        if (windowsTruncated || (raw.ime.visible && !imeInventoryBound) ||
            (!raw.ime.visible && rawImeWindows.isNotEmpty())
        ) {
            reasons += "ime_target_editor_unbound"
        }
        val imeMode = when {
            !raw.ime.visible -> ProbeImeMode.NONE
            !rawImeBoundsValid -> ProbeImeMode.UNKNOWN
            else -> raw.ime.mode
        }
        val imeBounds = if (raw.ime.visible) raw.ime.bounds else null
        val imeBinding = when {
            !raw.ime.visible -> "not_active"
            !imeInventoryBound -> "unknown"
            focusedInput == null -> "unknown"
            focusedInput.windowLabel == conversationWindowLabel -> "target_editor"
            else -> "other_editor"
        }
        if (raw.ime.visible && (imeMode != ProbeImeMode.DOCKED || imeBinding != "target_editor" ||
                focusedInput == null)
        ) reasons += "ime_target_editor_unbound"
        if (imeMode == ProbeImeMode.FLOATING) reasons += "floating_ime_unsupported"

        if (hasTargetOcclusion(
                windows = windows,
                targetWindowLabel = conversationWindowLabel,
                targetRegions = (regionCandidates.map { Triple(it.windowLabel, it.paneLabel, it.bounds) } +
                    titleCandidates.map { Triple(it.windowLabel, it.paneLabel, it.bounds) }).filter {
                    it.first == conversationWindowLabel && it.second == conversationPaneLabel
                }.map { it.third },
            )
        ) reasons += "overlay_target_occlusion"

        return TabletProbeFrame(
            captureId = raw.captureId,
            capturedAt = raw.capturedAt,
            capture = capture,
            display = ProbeDisplay(displayId, displaySize),
            windows = windows,
            windowsTruncated = windowsTruncated,
            panes = panes,
            panesTruncated = panesTruncated,
            nodeObservations = nodes,
            nodesTruncated = nodesTruncated,
            target = ProbeTargetObservation(
                expectedTitleHash = expectedTitleHash,
                conversationWindowLabel = conversationWindowLabel,
                conversationPaneLabel = conversationPaneLabel,
                titleCandidates = titleCandidates,
                toolbarCandidates = toolbarCandidates,
                messageCandidates = messageCandidates,
                inputCandidates = inputCandidates,
                focus = focus,
                ime = ProbeImeObservation(
                    visible = raw.ime.visible,
                    mode = imeMode,
                    bounds = imeBounds?.let { sanitizeRect(it, "region_geometry_invalid", reasons) },
                    // Hidden IME 永不携带 editor identity，避免把旧焦点误当成当前 session。
                    editorFingerprintHash = if (imeBinding == "target_editor") {
                        focusedInput?.editorFingerprintHash
                    } else {
                        null
                    },
                    binding = imeBinding,
                    targetInputCandidateLabel = if (imeBinding == "target_editor") {
                        focusedInput?.candidateLabel
                    } else {
                        null
                    },
                    captureToken = canonicalToken,
                ),
            ),
        )
    }

    private fun sanitizeWindow(
        raw: RawTabletWindow,
        label: String,
        reasons: MutableSet<String>,
    ): ProbeWindow {
        val type = raw.type
        val rootPackage = raw.rootPackage
        if (type == "application" &&
            (raw.rootStatus != ProbeRootStatus.READABLE || rootPackage != WECHAT_PACKAGE)
        ) reasons += "window_root_owner_conflict"
        val displayId = raw.displayId?.takeIf { it in 0..16 }
        val layer = raw.layer
        return ProbeWindow(
            windowLabel = label,
            displayId = displayId,
            type = type,
            rootPackage = rootPackage,
            layer = layer,
            bounds = sanitizeWindowRect(raw.bounds, required = true, reasons = reasons),
            touchableBounds = sanitizeWindowRect(
                raw.touchableBounds,
                required = false,
                reasons = reasons,
            ),
            rootStatus = raw.rootStatus,
            active = raw.active,
            focused = raw.focused,
        )
    }

    private fun provesToolbarTitle(
        node: RawTabletNode,
        nodeBounds: ProbeRect,
        toolbarBounds: ProbeRect,
        windowBounds: ProbeRect,
    ): Boolean {
        if (!node.visible || node.editable || node.scrollable || node.clickable) return false
        if (!toolbarBounds.contains(nodeBounds) || !windowBounds.contains(toolbarBounds)) return false
        val nearTop = toolbarBounds.top <= windowBounds.top + (windowBounds.height / 10).coerceAtLeast(1)
        val wide = toolbarBounds.width.toLong() * 10 >= windowBounds.width.toLong() * 7
        val shallow = toolbarBounds.height > 0 && toolbarBounds.height * 4 <= windowBounds.height
        val staticallyBound = node.toolbarAncestorBounds.any { it == toolbarBounds }
        return staticallyBound || (nearTop && wide && shallow)
    }

    private fun toolbarCandidateBounds(
        node: RawTabletNode,
        windowBounds: ProbeRect,
        reasons: MutableSet<String>,
    ): ProbeRect {
        val nodeBounds = sanitizeRect(node.bounds, "title_geometry_invalid", reasons)
        val maximumHeight = (windowBounds.height / 3).coerceAtLeast(nodeBounds.height)
        val validAncestors = node.ancestorBounds.asSequence()
            .filter(::validRect)
            .filter { it.contains(nodeBounds) }
            .filter { it.height in nodeBounds.height..maximumHeight }
            .toList()
        val staticToolbar = node.toolbarAncestorBounds.firstOrNull { it in validAncestors }
        if (staticToolbar != null) return staticToolbar
        return validAncestors.asSequence()
            .filter { candidate ->
                candidate.top <= windowBounds.top + (windowBounds.height / 10).coerceAtLeast(1) &&
                    candidate.width.toLong() * 10 >= windowBounds.width.toLong() * 7 &&
                    candidate.height * 4 <= windowBounds.height
            }
            .minByOrNull { candidate -> candidate.width.toLong() * candidate.height.toLong() }
            ?: nodeBounds
    }

    private fun regionsCloseConversationGeometry(
        pane: ProbePane?,
        toolbar: List<ProbeRegionCandidate>,
        message: List<ProbeRegionCandidate>,
        input: List<ProbeInputCandidate>,
    ): Boolean {
        val p = pane ?: return false
        val t = toolbar.singleOrNull()?.bounds ?: return false
        val m = message.singleOrNull()?.bounds ?: return false
        val i = input.singleOrNull()?.bounds ?: return false
        return listOf(t, m, i).all { validRect(it) && it.left == p.bounds.left && it.right == p.bounds.right } &&
            t.top == p.bounds.top && t.bottom == m.top && m.bottom == i.top && i.bottom == p.bounds.bottom
    }

    private fun hasTargetOcclusion(
        windows: List<ProbeWindow>,
        targetWindowLabel: String?,
        targetRegions: List<ProbeRect>,
    ): Boolean {
        val target = windows.singleOrNull { it.windowLabel == targetWindowLabel } ?: return false
        return windows.any { window ->
            window.type in setOf("accessibility_overlay", "system", "unknown") &&
                window.displayId != null && window.displayId == target.displayId &&
                window.layer > target.layer &&
                window.bounds?.let { bounds ->
                    validRect(bounds) && targetRegions.any { region ->
                        validRect(region) && bounds.intersects(region)
                    }
                } == true
        }
    }

    private fun candidatePaneRole(window: RawTabletWindow): ProbePaneRole = when {
        window.nodes.any { it.visible && it.editable && it.nodePackage == WECHAT_PACKAGE } ->
            ProbePaneRole.CONVERSATION
        window.nodes.any { it.visible && it.scrollable } -> ProbePaneRole.NAVIGATION
        else -> ProbePaneRole.UNKNOWN
    }

    private fun assignRunLocalWindowLabels(frames: List<RawTabletProbeFrame>): Map<Int, String> {
        val labels = LinkedHashMap<Int, String>()
        for (frame in frames) {
            selectRawWindows(frame)
                .forEach { window -> labels.getOrPut(window.rawWindowId) { "aw${labels.size + 1}" } }
        }
        return labels
    }

    private fun selectRawWindows(frame: RawTabletProbeFrame): List<RawTabletWindow> =
        frame.interactiveWindows.distinctBy { it.rawWindowId }
            .sortedWith(
                compareBy<RawTabletWindow>(
                    { it.type != "application" },
                    { it.bounds?.left ?: Int.MAX_VALUE },
                    { it.bounds?.top ?: Int.MAX_VALUE },
                    { -it.layer },
                    { it.rawWindowId },
                ),
            )
            .take(MAX_WINDOWS)

    private fun paneLabel(windowLabel: String): String = "ap${windowLabel.removePrefix("aw")}"

    private fun isRawAtomic(frame: RawTabletProbeFrame): Boolean =
        validRevision(frame.revisionBefore) &&
            frame.revisionBefore == frame.layoutRevision &&
            frame.revisionBefore == frame.imeRevision &&
            frame.revisionBefore == frame.revisionAfter

    private fun identitySetStable(frames: List<TabletProbeFrame>): Boolean {
        val first = frames.first().windows.map { it.windowLabel }.toSet()
        return frames.drop(1).all { frame -> frame.windows.map { it.windowLabel }.toSet() == first }
    }

    /** 忽略 frame-local node/candidate/capture labels，只比较可跨帧关联的语义、ownership 与几何。 */
    private fun semanticSignature(frame: TabletProbeFrame): List<Any?> = listOf(
        frame.display,
        frame.windowsTruncated,
        frame.panesTruncated,
        frame.nodesTruncated,
        canonicalRows(frame.windows.map { listOf(
            it.windowLabel, it.displayId, it.type, it.rootPackage, it.layer, it.bounds,
            it.touchableBounds, it.rootStatus, it.active, it.focused,
        ) }),
        canonicalRows(frame.panes.map {
            listOf(it.paneLabel, it.windowLabel, it.role, it.bounds, it.binding)
        }),
        frame.target.conversationWindowLabel,
        frame.target.conversationPaneLabel,
        canonicalRows(frame.target.titleCandidates.map { listOf(
            it.labelHash, it.semanticRole, it.windowLabel, it.paneLabel, it.bounds,
        ) }),
        canonicalRows(frame.target.toolbarCandidates.map {
            listOf(it.windowLabel, it.paneLabel, it.bounds)
        }),
        canonicalRows(frame.target.messageCandidates.map {
            listOf(it.windowLabel, it.paneLabel, it.bounds)
        }),
        canonicalRows(frame.target.inputCandidates.map { listOf(
            it.windowLabel, it.paneLabel, it.bounds, it.editable, it.focused, it.editorFingerprintHash,
        ) }),
        listOf(
            frame.target.focus.status,
            frame.target.focus.windowLabel,
            frame.target.focus.inputCandidateLabel,
        ),
        listOf(
            frame.target.ime.visible, frame.target.ime.mode, frame.target.ime.bounds,
            frame.target.ime.editorFingerprintHash, frame.target.ime.binding,
            frame.target.ime.targetInputCandidateLabel,
        ),
    )

    private fun canonicalRows(rows: List<List<Any?>>): List<String> =
        rows.map { row -> row.joinToString("|") { it?.toString() ?: "<null>" } }.sorted()

    private fun minimumIntervalMs(frames: List<RawTabletProbeFrame>): Long = runCatching {
        frames.zipWithNext().minOf { (before, after) ->
            Duration.between(Instant.parse(before.capturedAt), Instant.parse(after.capturedAt)).toMillis()
        }
    }.getOrDefault(-1)

    private fun captureSpan(frames: List<RawTabletProbeFrame>): Duration =
        Duration.between(
            Instant.parse(frames.first().capturedAt),
            Instant.parse(frames.last().capturedAt),
        )

    private fun addUpstreamT0Reasons(
        context: TabletProbeRunContext,
        firstFrameAt: Instant,
        reasons: MutableSet<String>,
    ) {
        val declared = context.upstreamT0
        val rawBytes = context.copyUpstreamT0RawUtf8()
        try {
            if (declared.artifactSha256 != probeSha256Bytes(rawBytes)) {
                reasons += "upstream_t0_hash_mismatch"
            }
            if (declared.producerCommitSha != TRUSTED_T0_PRODUCER_SHA) {
                reasons += "upstream_t0_producer_mismatch"
            }
            val actual = runCatching { parseActualT0(context.upstreamT0Tree) }.getOrNull()
            if (actual == null) {
                reasons += "upstream_t0_invalid"
                return
            }
            if (actual.schemaVersion != 5L || actual.runId != declared.runId ||
                actual.capturedAt != declared.capturedAt || actual.intakeStatus != "accepted" ||
                actual.readinessStatus != "blocked" || actual.p0Capability != "unsupported" ||
                actual.readinessReasons != declared.readinessReasons ||
                actual.p0UnsupportedReasons != declared.p0UnsupportedReasons
            ) reasons += "upstream_t0_invalid"
            if (actual.deviceProfileHash != declared.deviceProfileHash) {
                reasons += "upstream_t0_device_hash_mismatch"
            }
            val t0At = actual.capturedAt.takeIf(::isCanonicalProbeTimestamp)
                ?.let(Instant::parse)
            if (t0At == null || t0At > firstFrameAt ||
                Duration.between(t0At, firstFrameAt) > MAX_T0_AGE
            ) reasons += "upstream_t0_stale"
        } finally {
            rawBytes.fill(0)
        }
    }

    private fun parseActualT0(raw: StrictProbeJsonValue.ObjectValue): ActualT0 {
        val assessment = raw.objectValue("assessment")
        return ActualT0(
            schemaVersion = raw.longValue("schema_version"),
            runId = raw.stringValue("run_id"),
            capturedAt = raw.stringValue("captured_at_utc"),
            deviceProfileHash = probeDeviceProfileHash(raw.objectValue("device")),
            intakeStatus = assessment.stringValue("intake_status"),
            readinessStatus = assessment.stringValue("readiness_status"),
            readinessReasons = assessment.stringArray("readiness_block_reasons"),
            p0Capability = assessment.stringValue("p0_capability"),
            p0UnsupportedReasons = assessment.stringArray("p0_unsupported_reasons"),
        )
    }

    private data class ActualT0(
        val schemaVersion: Long,
        val runId: String,
        val capturedAt: String,
        val deviceProfileHash: String,
        val intakeStatus: String,
        val readinessStatus: String,
        val readinessReasons: List<String>,
        val p0Capability: String,
        val p0UnsupportedReasons: List<String>,
    )

    private fun requireValidContext(context: TabletProbeRunContext) {
        require(isSafeProbeId(context.runId)) { "tablet probe run id is invalid" }
        require(isStrictProbeHash(context.expectedTitleHash)) { "expected title hash is invalid" }
        require(context.provenance.kind in setOf("offline_fixture", "gateway_runtime_probe")) {
            "tablet probe provenance kind is invalid"
        }
        require(isSafeProbeId(context.provenance.name) && isSafeProbeId(context.provenance.version)) {
            "tablet probe provenance id is invalid"
        }
        require(GIT_SHA.matches(context.provenance.producerCommitSha)) {
            "tablet probe producer commit is invalid"
        }
        require(isStrictProbeHash(context.provenance.producerArtifactSha256)) {
            "tablet probe producer artifact hash is invalid"
        }
        val upstream = context.upstreamT0
        require(upstream.sourceKind in setOf("offline_fixture", "trusted_runtime")) {
            "tablet probe upstream source is invalid"
        }
        require(isSafeProbeId(upstream.runId) && isCanonicalProbeTimestamp(upstream.capturedAt)) {
            "tablet probe upstream identity is invalid"
        }
        require(isStrictProbeHash(upstream.artifactSha256) &&
            GIT_SHA.matches(upstream.producerCommitSha) &&
            isStrictProbeHash(upstream.deviceProfileHash)
        ) { "tablet probe upstream provenance is invalid" }
        require(upstream.readinessReasons.size in 1..64 &&
            upstream.readinessReasons.distinct().size == upstream.readinessReasons.size &&
            upstream.readinessReasons.all(::isSafeProbeId)
        ) { "tablet probe upstream readiness reasons are invalid" }
        require(upstream.p0UnsupportedReasons.size in 2..64 &&
            upstream.p0UnsupportedReasons.distinct().size == upstream.p0UnsupportedReasons.size &&
            upstream.p0UnsupportedReasons.all(::isSafeProbeId) &&
            "wechat_layout_unverified" in upstream.p0UnsupportedReasons &&
            "tablet_landscape_p0_unimplemented" in upstream.p0UnsupportedReasons
        ) { "tablet probe upstream P0 reasons are invalid" }
    }

    private fun sanitizeRect(
        rect: ProbeRect,
        reason: String,
        reasons: MutableSet<String>,
    ): ProbeRect {
        require(schemaRect(rect)) { "semantic probe bounds exceed the closed schema" }
        if (rect.width <= 0 || rect.height <= 0) reasons += reason
        return rect
    }

    private fun sanitizeWindowRect(
        rect: ProbeRect?,
        required: Boolean,
        reasons: MutableSet<String>,
    ): ProbeRect? {
        if (rect == null) {
            if (required) reasons += "window_geometry_invalid"
            return null
        }
        if (!schemaRect(rect)) {
            if (required) reasons += "window_geometry_invalid"
            return null
        }
        if (rect.width <= 0 || rect.height <= 0) reasons += "window_geometry_invalid"
        return rect
    }

    private fun sanitizeNodeRole(role: String, reasons: MutableSet<String>): String =
        role.takeIf { it in NODE_ROLES } ?: "other".also { reasons += "node_binding_invalid" }

    private fun validRect(rect: ProbeRect): Boolean = schemaRect(rect) && rect.width > 0 && rect.height > 0
    private fun schemaRect(rect: ProbeRect): Boolean = rect.isSchemaBounded()

    private fun validSize(size: ProbeSize): Boolean = size.width in 1..16_384 && size.height in 1..16_384
    private fun validRevision(value: Long): Boolean = value in 1..Int.MAX_VALUE.toLong()

    private val WINDOW_TYPES = setOf(
        "application", "input_method", "accessibility_overlay", "system", "unknown",
    )
    private val NODE_ROLES = setOf(
        "toolbar_title", "conversation_row", "message_viewport", "input_editor", "container", "other",
    )
}

/** 与 v2 contract 固定的 title canonical hash。Android adapter 只对有长度预算的文本调用。 */
internal fun probeContentHash(text: CharSequence): String {
    val canonical = Normalizer.normalize(text.toString(), Normalizer.Form.NFKC).trim()
    return probeSha256Bytes(canonical.toByteArray(StandardCharsets.UTF_8))
}

internal enum class ProbeTitleContentMatch { MATCH, NO_MATCH, OVER_BUDGET }

/** 先按 CharSequence.length 常数时间拒绝超限内容，绝不先 toString/normalize/hash。 */
internal fun probeMatchesExpectedTitle(
    content: CharSequence?,
    expectedTitleHash: String,
): ProbeTitleContentMatch = when {
    content == null || content.length == 0 -> ProbeTitleContentMatch.NO_MATCH
    content.length > MAX_TITLE_HASH_CHARACTERS -> ProbeTitleContentMatch.OVER_BUDGET
    probeContentHash(content) == expectedTitleHash -> ProbeTitleContentMatch.MATCH
    else -> ProbeTitleContentMatch.NO_MATCH
}

internal fun isStrictProbeHash(value: String): Boolean = STRICT_PROBE_HASH.matches(value)

/** input fingerprint 仅同一次 run 可关联；salt/raw structural material 都不进入 JSON。 */
internal fun probeRunSaltedHash(runSalt: ByteArray, material: String): String {
    require(runSalt.size >= 32) { "tablet probe run salt must contain at least 32 bytes" }
    val digest = MessageDigest.getInstance("SHA-256")
    digest.update(runSalt)
    digest.update(0.toByte())
    digest.update(material.toByteArray(StandardCharsets.UTF_8))
    return "sha256:" + digest.digest().joinToString("") { "%02x".format(it) }
}

internal fun probeSha256Bytes(bytes: ByteArray): String =
    "sha256:" + MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

internal fun probeDeviceProfileHash(device: StrictProbeJsonValue.ObjectValue): String = probeSha256Bytes(
    ("tablet-t0-device-profile/v2\n" + canonicalProbeJson(device)).toByteArray(StandardCharsets.UTF_8),
)

internal sealed interface StrictProbeJsonValue {
    class ObjectValue internal constructor(val members: Map<String, StrictProbeJsonValue>) : StrictProbeJsonValue
    class ArrayValue internal constructor(val values: List<StrictProbeJsonValue>) : StrictProbeJsonValue
    data class StringValue(val value: String) : StrictProbeJsonValue
    data class LongValue(val value: Long) : StrictProbeJsonValue
    data class BooleanValue(val value: Boolean) : StrictProbeJsonValue
    object NullValue : StrictProbeJsonValue
}

internal fun parseStrictProbeJson(bytes: ByteArray): StrictProbeJsonValue.ObjectValue {
    require(bytes.size in 1..65_536) { "strict T0 JSON byte length is invalid" }
    require(!(bytes.size >= 3 && bytes[0] == 0xef.toByte() && bytes[1] == 0xbb.toByte() &&
        bytes[2] == 0xbf.toByte())) { "strict T0 JSON must be BOM-less" }
    val decoder = StandardCharsets.UTF_8.newDecoder()
        .onMalformedInput(CodingErrorAction.REPORT)
        .onUnmappableCharacter(CodingErrorAction.REPORT)
    val decoded = try {
        decoder.decode(ByteBuffer.wrap(bytes)).toString()
    } catch (_: Exception) {
        throw IllegalArgumentException("strict T0 JSON is not valid UTF-8")
    }
    return StrictProbeJsonParser(decoded).parseObjectRoot()
}

private class StrictProbeJsonParser(private val source: String) {
    private var index = 0
    private var nodeCount = 0

    fun parseObjectRoot(): StrictProbeJsonValue.ObjectValue {
        skipWhitespace()
        val value = parseValue(depth = 1)
        skipWhitespace()
        require(index == source.length && value is StrictProbeJsonValue.ObjectValue) {
            "strict T0 JSON must contain exactly one object"
        }
        return value
    }

    private fun parseValue(depth: Int): StrictProbeJsonValue {
        require(depth <= MAX_JSON_DEPTH) { "strict T0 JSON nesting is too deep" }
        nodeCount += 1
        require(nodeCount <= MAX_JSON_NODES) { "strict T0 JSON contains too many values" }
        skipWhitespace()
        return when (peek()) {
            '{' -> parseObject(depth)
            '[' -> parseArray(depth)
            '"' -> StrictProbeJsonValue.StringValue(parseString())
            't' -> parseKeyword("true", StrictProbeJsonValue.BooleanValue(true))
            'f' -> parseKeyword("false", StrictProbeJsonValue.BooleanValue(false))
            'n' -> parseKeyword("null", StrictProbeJsonValue.NullValue)
            '-', in '0'..'9' -> StrictProbeJsonValue.LongValue(parseLong())
            else -> invalidJson()
        }
    }

    private fun parseObject(depth: Int): StrictProbeJsonValue.ObjectValue {
        expect('{')
        skipWhitespace()
        val members = linkedMapOf<String, StrictProbeJsonValue>()
        if (consume('}')) return immutableObject(members)
        while (true) {
            require(peek() == '"') { "strict T0 JSON object key must be a string" }
            val key = parseString()
            require(!members.containsKey(key)) { "strict T0 JSON contains a duplicate object key" }
            skipWhitespace()
            expect(':')
            members[key] = parseValue(depth + 1)
            skipWhitespace()
            if (consume('}')) return immutableObject(members)
            expect(',')
            skipWhitespace()
            require(peek() != '}') { "strict T0 JSON has a trailing object comma" }
        }
    }

    private fun parseArray(depth: Int): StrictProbeJsonValue.ArrayValue {
        expect('[')
        skipWhitespace()
        val values = mutableListOf<StrictProbeJsonValue>()
        if (consume(']')) return immutableArray(values)
        while (true) {
            values += parseValue(depth + 1)
            skipWhitespace()
            if (consume(']')) return immutableArray(values)
            expect(',')
            skipWhitespace()
            require(peek() != ']') { "strict T0 JSON has a trailing array comma" }
        }
    }

    private fun parseString(): String {
        expect('"')
        val out = StringBuilder()
        while (index < source.length) {
            val character = source[index++]
            when {
                character == '"' -> return out.toString()
                character == '\\' -> appendEscape(out)
                character.code < 0x20 -> invalidJson()
                Character.isHighSurrogate(character) -> {
                    require(index < source.length && Character.isLowSurrogate(source[index])) {
                        "strict T0 JSON contains an unpaired surrogate"
                    }
                    out.append(character).append(source[index++])
                }
                Character.isLowSurrogate(character) ->
                    throw IllegalArgumentException("strict T0 JSON contains an unpaired surrogate")
                else -> out.append(character)
            }
        }
        invalidJson()
    }

    private fun appendEscape(out: StringBuilder) {
        val escape = next()
        when (escape) {
            '"', '\\', '/' -> out.append(escape)
            'b' -> out.append('\b')
            'f' -> out.append('\u000c')
            'n' -> out.append('\n')
            'r' -> out.append('\r')
            't' -> out.append('\t')
            'u' -> {
                val first = readHexQuad()
                when {
                    first in 0xd800..0xdbff -> {
                        require(next() == '\\' && next() == 'u') {
                            "strict T0 JSON contains an unpaired surrogate escape"
                        }
                        val second = readHexQuad()
                        require(second in 0xdc00..0xdfff) {
                            "strict T0 JSON contains an unpaired surrogate escape"
                        }
                        out.append(first.toChar()).append(second.toChar())
                    }
                    first in 0xdc00..0xdfff ->
                        throw IllegalArgumentException("strict T0 JSON contains an unpaired surrogate escape")
                    else -> out.append(first.toChar())
                }
            }
            else -> invalidJson()
        }
    }

    private fun parseLong(): Long {
        val start = index
        consume('-')
        val first = peek()
        when {
            first == '0' -> {
                index += 1
                require(peekOrNull() !in '0'..'9') {
                    "strict T0 JSON integer is not canonical"
                }
            }
            first in '1'..'9' -> {
                index += 1
                while (peekOrNull() in '0'..'9') index += 1
            }
            else -> invalidJson()
        }
        require(peekOrNull() !in setOf('.', 'e', 'E')) { "strict T0 JSON number must be Int64" }
        return source.substring(start, index).toLongOrNull()
            ?: throw IllegalArgumentException("strict T0 JSON integer exceeds Int64")
    }

    private fun readHexQuad(): Int {
        require(index + 4 <= source.length) { "strict T0 JSON has a short unicode escape" }
        var value = 0
        repeat(4) {
            val digit = when (val character = source[index++]) {
                in '0'..'9' -> character - '0'
                in 'a'..'f' -> character - 'a' + 10
                in 'A'..'F' -> character - 'A' + 10
                else -> invalidJson()
            }
            value = value * 16 + digit
        }
        return value
    }

    private fun <T : StrictProbeJsonValue> parseKeyword(token: String, value: T): T {
        require(source.regionMatches(index, token, 0, token.length)) { "strict T0 JSON literal is invalid" }
        index += token.length
        return value
    }

    private fun skipWhitespace() {
        while (peekOrNull() in JSON_WHITESPACE) index += 1
    }

    private fun expect(expected: Char) {
        require(next() == expected) { "strict T0 JSON delimiter is invalid" }
    }

    private fun consume(expected: Char): Boolean {
        if (peekOrNull() != expected) return false
        index += 1
        return true
    }

    private fun next(): Char = if (index < source.length) source[index++] else invalidJson()
    private fun peek(): Char = peekOrNull() ?: invalidJson()
    private fun peekOrNull(): Char? = source.getOrNull(index)
    private fun invalidJson(): Nothing = throw IllegalArgumentException("strict T0 JSON syntax is invalid")

    private fun immutableObject(
        members: LinkedHashMap<String, StrictProbeJsonValue>,
    ): StrictProbeJsonValue.ObjectValue = StrictProbeJsonValue.ObjectValue(
        Collections.unmodifiableMap(LinkedHashMap(members)),
    )

    private fun immutableArray(
        values: List<StrictProbeJsonValue>,
    ): StrictProbeJsonValue.ArrayValue = StrictProbeJsonValue.ArrayValue(
        Collections.unmodifiableList(ArrayList(values)),
    )

    private companion object {
        const val MAX_JSON_DEPTH = 64
        const val MAX_JSON_NODES = 8_192
        val JSON_WHITESPACE = setOf(' ', '\t', '\r', '\n')
    }
}

internal fun canonicalProbeJson(value: StrictProbeJsonValue): String = when (value) {
    is StrictProbeJsonValue.ObjectValue -> value.members.keys.sorted().joinToString(",", "{", "}") { key ->
        canonicalProbeJsonString(key) + ":" + canonicalProbeJson(value.members.getValue(key))
    }
    is StrictProbeJsonValue.ArrayValue ->
        value.values.joinToString(",", "[", "]", transform = ::canonicalProbeJson)
    is StrictProbeJsonValue.StringValue -> canonicalProbeJsonString(value.value)
    is StrictProbeJsonValue.LongValue -> value.value.toString()
    is StrictProbeJsonValue.BooleanValue -> value.value.toString()
    StrictProbeJsonValue.NullValue -> "null"
}

private fun canonicalProbeJsonString(value: String): String = buildString(value.length + 2) {
    append('"')
    for (character in value) {
        when (character) {
            '"' -> append("\\\"")
            '\\' -> append("\\\\")
            '\b' -> append("\\b")
            '\t' -> append("\\t")
            '\n' -> append("\\n")
            '\u000c' -> append("\\f")
            '\r' -> append("\\r")
            else -> when {
                character.code in 0x00..0x1f || character.code == 0x85 ||
                    character.code == 0x2028 || character.code == 0x2029 ->
                    appendLowerUnicodeEscape(character.code)
                else -> append(character)
            }
        }
    }
    append('"')
}

private fun StringBuilder.appendLowerUnicodeEscape(code: Int) {
    append("\\u")
    for (shift in intArrayOf(12, 8, 4, 0)) append(LOWER_HEX[(code shr shift) and 0x0f])
}

private fun StrictProbeJsonValue.ObjectValue.objectValue(name: String): StrictProbeJsonValue.ObjectValue =
    members[name] as? StrictProbeJsonValue.ObjectValue
        ?: throw IllegalArgumentException("strict T0 JSON object field is invalid")

private fun StrictProbeJsonValue.ObjectValue.stringValue(name: String): String =
    (members[name] as? StrictProbeJsonValue.StringValue)?.value
        ?: throw IllegalArgumentException("strict T0 JSON string field is invalid")

private fun StrictProbeJsonValue.ObjectValue.longValue(name: String): Long =
    (members[name] as? StrictProbeJsonValue.LongValue)?.value
        ?: throw IllegalArgumentException("strict T0 JSON integer field is invalid")

private fun StrictProbeJsonValue.ObjectValue.stringArray(name: String): List<String> =
    ((members[name] as? StrictProbeJsonValue.ArrayValue)?.values
        ?: throw IllegalArgumentException("strict T0 JSON array field is invalid")).map { value ->
        (value as? StrictProbeJsonValue.StringValue)?.value
            ?: throw IllegalArgumentException("strict T0 JSON string array is invalid")
    }

private val LOWER_HEX = "0123456789abcdef".toCharArray()

private fun deriveRunSalt(baseSalt: ByteArray, runId: String): ByteArray =
    MessageDigest.getInstance("SHA-256").run {
        update(baseSalt)
        update(0.toByte())
        update(runId.toByteArray(StandardCharsets.UTF_8))
        digest()
    }

private fun isSafeProbeId(value: String): Boolean = SAFE_PROBE_ID.matches(value)
private fun isCanonicalProbeTimestamp(value: String): Boolean =
    CANONICAL_TIMESTAMP.matches(value) && runCatching { Instant.parse(value) }.isSuccess

private val STRICT_PROBE_HASH = Regex("sha256:[0-9a-f]{64}")
private val SAFE_PROBE_ID = Regex("[a-z0-9][a-z0-9._-]{0,79}")
private val GIT_SHA = Regex("[0-9a-f]{40}")
private val CANONICAL_TIMESTAMP = Regex(
    "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{7}Z",
)
