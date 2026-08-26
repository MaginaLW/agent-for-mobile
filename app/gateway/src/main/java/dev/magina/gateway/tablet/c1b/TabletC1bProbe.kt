package dev.magina.gateway.tablet.c1b

import java.time.Instant
import java.time.format.DateTimeFormatterBuilder

internal interface C1bWindowHandle
internal interface C1bNodeHandle

/**
 * The only platform dependency surface for C1b. Every method returns one read-only fact. The interface exposes no
 * mutation, target selection, application lifecycle, image capture, text dump, or external storage capability.
 */
internal interface TabletC1bReadPort {
    fun currentRevision(): Long
    fun display(): C1bDisplayRead
    fun windows(): List<C1bWindowHandle>
    fun windowId(window: C1bWindowHandle): Int
    fun platformTypeCode(window: C1bWindowHandle): Int
    fun windowDisplayId(window: C1bWindowHandle): Int
    fun windowLayer(window: C1bWindowHandle): Int
    fun windowBounds(window: C1bWindowHandle): C1bRect?
    fun windowTouchableBounds(window: C1bWindowHandle): C1bRect?
    fun windowActive(window: C1bWindowHandle): Boolean
    fun windowFocused(window: C1bWindowHandle): Boolean
    fun windowExpectedTitleMatch(window: C1bWindowHandle, expectedTitleHash: String): C1bTitleMatchStatus
    fun root(window: C1bWindowHandle): C1bNodeHandle?

    /** Exact same-frame node identity; implementations must not reduce this comparison to hash equality. */
    fun nodesExactlyEqual(first: C1bNodeHandle, second: C1bNodeHandle): Boolean
    fun nodeRefresh(node: C1bNodeHandle): Boolean
    fun nodeWindowId(node: C1bNodeHandle): Int
    fun nodePackageName(node: C1bNodeHandle): String?
    fun nodeBounds(node: C1bNodeHandle): C1bRect?
    fun nodeVisible(node: C1bNodeHandle): Boolean
    fun nodeEnabled(node: C1bNodeHandle): Boolean
    fun nodeEditable(node: C1bNodeHandle): Boolean
    fun nodeScrollable(node: C1bNodeHandle): Boolean
    fun nodeFocused(node: C1bNodeHandle): Boolean
    fun nodeChildCount(node: C1bNodeHandle): Int
    fun nodeChild(node: C1bNodeHandle, index: Int): C1bNodeHandle?
    fun inputFocusNode(): C1bNodeHandle?
}

internal data class C1bCaptureRequest(
    val captureId: String,
    val captureToken: String,
    val expectedTitleHash: String,
) {
    init {
        require(C1B_SAFE_ID.matches(captureId)) { "C1b capture id is invalid" }
        require(captureToken == "c1" || captureToken == "c2") { "C1b capture token is invalid" }
        require(C1B_STRICT_SHA256.matches(expectedTitleHash)) { "C1b expected title hash is invalid" }
    }
}

internal data class C1bProbeLimits(
    val maximumWindows: Int = 16,
    val maximumPanes: Int = 8,
    val maximumNodesPerWindow: Int = 128,
    val maximumTotalNodes: Int = 512,
    val maximumDepth: Int = 60,
    val maximumChildrenPerNode: Int = 256,
) {
    init {
        require(maximumWindows in 1..16)
        require(maximumPanes in 1..8)
        require(maximumNodesPerWindow in 1..512)
        require(maximumTotalNodes in 1..512)
        require(maximumDepth in 1..128)
        require(maximumChildrenPerNode in 1..512)
    }
}

/** Captures one raw frame. [TabletC1bAssembler] is the only component that emits the two-frame evidence object. */
internal class TabletC1bProbe(
    private val port: TabletC1bReadPort,
    private val limits: C1bProbeLimits = C1bProbeLimits(),
    private val now: () -> Instant = Instant::now,
) {
    fun capture(request: C1bCaptureRequest): C1bRawFrame {
        val diagnosticCodes = linkedSetOf<String>()
        val revisionBefore = readRevision("revision_before_read_failed")
        val display = port.display()
        val windowsAttempt = attempt { port.windows().toList() }
        val allHandles = windowsAttempt.value.orEmpty()
        var windowsTruncated = !windowsAttempt.succeeded || allHandles.size > limits.maximumWindows
        if (!windowsAttempt.succeeded) diagnosticCodes += "window_inventory_truncated"

        val states = allHandles.take(limits.maximumWindows).mapIndexedNotNull { index, handle ->
            captureWindowShell(index + 1, handle, display, request.expectedTitleHash, diagnosticCodes)
                ?: null.also { windowsTruncated = true }
        }
        val applicationStates = states.filter { it.type == "application" }
        val paneEligible = applicationStates.filter {
            it.rootHandleStatus == C1bRootHandleStatus.READABLE &&
                it.rootWindowBinding == C1bWindowBinding.EXACT && it.bounds?.isPositive == true &&
                it.rootNode != null && it.rootIdentity != null
        }
        val panesTruncated = paneEligible.size > limits.maximumPanes
        if (panesTruncated) diagnosticCodes += "window_root_projection_invalid"
        paneEligible.take(limits.maximumPanes).forEach { state ->
            state.paneLabel = "ap${state.provisionalIndex}"
            state.enqueueRoot()
        }
        applicationStates.filter { it.paneLabel == null && it.subtreeStatus == null }.forEach { state ->
            state.readError("root_projection_unavailable")
        }

        val nextNodeOrdinal = intArrayOf(1)
        val totalUsed = traverseFairly(states, nextNodeOrdinal)
        if (totalUsed >= limits.maximumTotalNodes) {
            states.filter { it.queue.isNotEmpty() }.forEach(MutableWindowState::markBudgetExhausted)
        }
        states.forEach(MutableWindowState::finishSubtree)
        val layoutRevision = readRevision("layout_revision_read_failed")

        val nodesTruncated = panesTruncated || states.any { it.budgetExhausted }
        val windowTypeInventoryComplete = states.none { it.type == "unknown" }
        val focus = classifyFocus(
            states,
            windowsTruncated || !windowTypeInventoryComplete,
            nodesTruncated,
            diagnosticCodes,
        )
        val windows = states.map(MutableWindowState::freeze)
        val panes = states.mapNotNull { state ->
            val paneLabel = state.paneLabel ?: return@mapNotNull null
            val bounds = state.bounds ?: return@mapNotNull null
            C1bPaneObservation(paneLabel, state.windowLabel, bounds)
        }
        val nodes = states.flatMap { it.nodes }.sortedBy(::nodeOrdinal)
        val ime = captureIme(
            windows,
            focus,
            request.captureToken,
            !windowsTruncated && windowTypeInventoryComplete,
        )
        val imeRevision = readRevision("ime_revision_read_failed")
        val revisionAfter = readRevision("revision_after_read_failed")

        states.forEach { diagnosticCodes += it.diagnosticCodes }
        if (windowsTruncated) diagnosticCodes += "window_inventory_truncated"
        if (nodesTruncated) diagnosticCodes += "subtree_capture_incomplete"
        return C1bRawFrame(
            captureId = request.captureId,
            capturedAt = C1B_INSTANT_FORMATTER.format(now()),
            capture = C1bCaptureMetadata(
                token = request.captureToken,
                revisionBefore = revisionBefore,
                revisionAfter = revisionAfter,
                layoutRevision = layoutRevision,
                imeRevision = imeRevision,
            ),
            display = display,
            windows = windows,
            windowsTruncated = windowsTruncated,
            panes = panes,
            panesTruncated = panesTruncated,
            nodes = nodes,
            nodesTruncated = nodesTruncated,
            focus = focus,
            ime = ime,
            expectedTitleHash = request.expectedTitleHash,
            windowIdentityTokens = states.mapNotNull { state ->
                state.rawWindowId?.let { state.windowLabel to it }
            }.toMap(),
            nodeIdentityTokens = states.flatMap { state ->
                state.nodeMetadata.filter {
                    it.observation.windowIdBinding == C1bWindowBinding.EXACT
                }.map { metadata -> metadata.nodeLabel to metadata.identity }
            }.toMap(),
            diagnosticCodes = diagnosticCodes,
        )
    }

    private fun captureWindowShell(
        provisionalIndex: Int,
        handle: C1bWindowHandle,
        display: C1bDisplayRead,
        expectedTitleHash: String,
        frameCodes: MutableSet<String>,
    ): MutableWindowState? {
        val platformTypeAttempt = attempt { port.platformTypeCode(handle) }
        val platformTypeCode = platformTypeAttempt.value
        if (!platformTypeAttempt.succeeded || platformTypeCode == null || platformTypeCode !in 0..255) {
            frameCodes += if (platformTypeAttempt.succeeded) "window_type_invalid" else "window_type_read_failed"
            return null
        }
        val displayAttempt = attempt { port.windowDisplayId(handle) }
        val windowDisplayId = displayAttempt.value
        if (!displayAttempt.succeeded || windowDisplayId == null || windowDisplayId !in 0..16) {
            frameCodes += if (displayAttempt.succeeded) "window_display_invalid" else "window_display_read_failed"
            return null
        }
        val layerAttempt = attempt { port.windowLayer(handle) }
        val windowLayer = layerAttempt.value
        if (!layerAttempt.succeeded || windowLayer == null || windowLayer !in -32_768..32_767) {
            frameCodes += if (layerAttempt.succeeded) "window_layer_invalid" else "window_layer_read_failed"
            return null
        }
        val touchableAttempt = attempt { port.windowTouchableBounds(handle) }
        val touchableBounds = touchableAttempt.value
        if (!touchableAttempt.succeeded || touchableBounds?.isSchemaBounded == false) {
            frameCodes += if (touchableAttempt.succeeded) {
                "window_touchable_bounds_invalid"
            } else {
                "window_touchable_bounds_read_failed"
            }
            return null
        }
        val activeAttempt = attempt { port.windowActive(handle) }
        val windowActive = activeAttempt.value
        if (!activeAttempt.succeeded || windowActive == null) {
            frameCodes += "window_active_read_failed"
            return null
        }
        val focusAttempt = attempt { port.windowFocused(handle) }
        val windowFocused = focusAttempt.value
        if (!focusAttempt.succeeded || windowFocused == null) {
            frameCodes += "window_focus_read_failed"
            return null
        }
        val windowIdAttempt = attempt { port.windowId(handle) }
        val rawWindowId = windowIdAttempt.value
        if (!windowIdAttempt.succeeded || rawWindowId == null || !c1bIsDefinedWindowId(rawWindowId)) {
            frameCodes += if (windowIdAttempt.succeeded) "window_id_invalid" else "window_id_read_failed"
            return null
        }
        val state = MutableWindowState(provisionalIndex, handle, limits.maximumNodesPerWindow)
        state.rawWindowId = rawWindowId
        state.platformTypeCode = platformTypeCode
        state.type = c1bPlatformWindowTypeName(state.platformTypeCode)
        state.displayId = windowDisplayId
        state.layer = windowLayer
        state.bounds = boundedRectRead(state, "window_bounds_read_failed", "window_bounds_invalid") {
            port.windowBounds(handle)
        }
        state.touchableBounds = touchableBounds
        state.active = windowActive
        state.windowFocusReadable = true
        state.focused = windowFocused

        state.expectedWindowTitleMatch = if (state.type == "application") {
            val attempted = attempt { port.windowExpectedTitleMatch(handle, expectedTitleHash) }
            if (!attempted.succeeded) {
                state.structuralError("window_title_read_failed")
                C1bTitleMatchStatus.READ_ERROR
            } else {
                attempted.value?.takeIf {
                    it != C1bTitleMatchStatus.NOT_ATTEMPTED && it != C1bTitleMatchStatus.READ_ERROR
                } ?: C1bTitleMatchStatus.READ_ERROR.also {
                    state.structuralError("window_title_result_invalid")
                }
            }
        } else {
            C1bTitleMatchStatus.NOT_ATTEMPTED
        }

        val rootAttempt = attempt { port.root(handle) }
        val root = rootAttempt.value
        when {
            !rootAttempt.succeeded -> {
                state.rootHandleStatus = C1bRootHandleStatus.UNREADABLE
                state.rootWindowBinding = C1bWindowBinding.UNKNOWN
                if (state.type == "application") state.readError("root_read_failed")
            }
            root == null -> {
                state.rootHandleStatus = C1bRootHandleStatus.ABSENT
                state.rootWindowBinding = C1bWindowBinding.UNKNOWN
                state.subtreeStatus = C1bSubtreeStatus.NOT_ATTEMPTED
            }
            else -> {
                state.rootHandleStatus = C1bRootHandleStatus.READABLE
                state.rootNode = root
                val rootWindowIdAttempt = attempt { port.nodeWindowId(root) }
                val rawRootWindowId = rootWindowIdAttempt.value
                val rootWindowId = rawRootWindowId?.takeIf(::c1bIsDefinedWindowId)
                when {
                    !rootWindowIdAttempt.succeeded -> state.structuralError("root_window_id_read_failed")
                    rootWindowId == null -> state.readError("root_window_id_invalid")
                }
                state.rootWindowBinding = when {
                    rootWindowId == null || state.rawWindowId == null -> C1bWindowBinding.UNKNOWN
                    rootWindowId == state.rawWindowId -> C1bWindowBinding.EXACT
                    else -> C1bWindowBinding.MISMATCH
                }
                state.rootPackage = state.read("root_package_read_failed") { port.nodePackageName(root) }
                    ?.takeIf(C1B_SAFE_ID::matches)
                if (state.rootPackage == null) state.structuralError("root_package_unavailable")
                if (state.rootWindowBinding != C1bWindowBinding.EXACT && state.type == "application") {
                    state.readError("root_window_binding_invalid")
                }
                state.rootIdentity = C1bNodeIdentityToken("r")
                state.knownNodes += root
            }
        }
        if (state.displayId != display.displayId) frameCodes += "multi_display_blocked"
        return state
    }

    private fun boundedRectRead(
        state: MutableWindowState,
        readFailure: String,
        invalid: String,
        subtree: Boolean = false,
        block: () -> C1bRect?,
    ): C1bRect? {
        val result = attempt(block)
        if (!result.succeeded) {
            if (subtree) state.readError(readFailure) else state.structuralError(readFailure)
            return null
        }
        val raw = result.value
        if (raw != null && !raw.isSchemaBounded) {
            if (subtree) state.readError(invalid) else state.structuralError(invalid)
            return null
        }
        return raw
    }

    private fun traverseFairly(states: List<MutableWindowState>, nextNodeOrdinal: IntArray): Int {
        var totalUsed = 0
        while (totalUsed < limits.maximumTotalNodes) {
            var progressed = false
            states.forEach { state ->
                if (totalUsed >= limits.maximumTotalNodes || state.queue.isEmpty()) return@forEach
                if (state.budgetUsed >= state.budgetLimit) {
                    state.markBudgetExhausted()
                    return@forEach
                }
                val work = state.queue.removeFirst()
                state.budgetUsed += 1
                totalUsed += 1
                progressed = true
                processNode(state, work, nextNodeOrdinal[0]++)
            }
            if (!progressed) break
        }
        return totalUsed
    }

    private fun processNode(state: MutableWindowState, work: NodeWork, ordinal: Int) {
        val nodeLabel = "an$ordinal"
        var focusFactsReadable = true
        val nodeWindowAttempt = attempt { port.nodeWindowId(work.node) }
        val rawNodeWindowId = nodeWindowAttempt.value
        val nodeWindowId = rawNodeWindowId?.takeIf(::c1bIsDefinedWindowId)
        if (!nodeWindowAttempt.succeeded) {
            focusFactsReadable = false
            state.readError("node_window_id_read_failed")
        } else if (nodeWindowId == null) {
            focusFactsReadable = false
            state.readError("node_window_id_invalid")
        }
        val binding = when {
            nodeWindowId == null || state.rawWindowId == null -> C1bWindowBinding.UNKNOWN
            nodeWindowId == state.rawWindowId -> C1bWindowBinding.EXACT
            else -> C1bWindowBinding.MISMATCH
        }
        if (binding != C1bWindowBinding.EXACT) state.readError("node_window_binding_invalid")

        val rawBoundsAttempt = attempt { port.nodeBounds(work.node) }
        val rawBounds = when {
            !rawBoundsAttempt.succeeded -> null.also {
                focusFactsReadable = false
                state.readError("node_bounds_read_failed")
            }
            rawBoundsAttempt.value?.isSchemaBounded == false -> null.also {
                focusFactsReadable = false
                state.readError("node_bounds_invalid")
            }
            else -> rawBoundsAttempt.value
        }
        val geometry = when {
            rawBounds == null -> C1bGeometryStatus.UNAVAILABLE
            rawBounds.isPositive -> C1bGeometryStatus.POSITIVE
            else -> C1bGeometryStatus.DEGENERATE
        }
        val visibleAttempt = attempt { port.nodeVisible(work.node) }
        val visible = visibleAttempt.value == true
        if (!visibleAttempt.succeeded) {
            focusFactsReadable = false
            state.readError("node_visible_read_failed")
        }
        val enabledAttempt = attempt { port.nodeEnabled(work.node) }
        val enabled = enabledAttempt.value == true
        if (!enabledAttempt.succeeded) {
            focusFactsReadable = false
            state.readError("node_enabled_read_failed")
        }
        val editableAttempt = attempt { port.nodeEditable(work.node) }
        val editable = editableAttempt.value == true
        if (!editableAttempt.succeeded) {
            focusFactsReadable = false
            state.readError("node_editable_read_failed")
        }
        val scrollable = state.readNode("node_scrollable_read_failed") { port.nodeScrollable(work.node) } ?: false
        val focusedAttempt = attempt { port.nodeFocused(work.node) }
        val focused = focusedAttempt.value == true
        if (!focusedAttempt.succeeded) {
            focusFactsReadable = false
            state.readError("node_focus_read_failed")
        }
        val packageAttempt = attempt { port.nodePackageName(work.node) }
        val packageName = packageAttempt.value?.takeIf(C1B_SAFE_ID::matches)
        if (!packageAttempt.succeeded) {
            focusFactsReadable = false
            state.readError("node_package_read_failed")
        } else if (packageAttempt.value != null && packageName == null) {
            focusFactsReadable = false
            state.readError("node_package_invalid")
        }
        val paneLabel = requireNotNull(state.paneLabel)
        val observation = C1bNodeObservation(
            nodeLabel = nodeLabel,
            windowLabel = state.windowLabel,
            paneLabel = paneLabel,
            isRoot = work.isRoot,
            windowIdBinding = binding,
            geometryStatus = geometry,
            bounds = rawBounds,
            visible = visible,
            enabled = enabled,
            editable = editable,
            scrollable = scrollable,
            focused = focused,
        )
        state.nodes += observation
        state.nodeMetadata += NodeMetadata(
            identity = work.identity,
            handle = work.node,
            nodeLabel = nodeLabel,
            observation = observation,
            packageName = packageName,
            focusFactsReadable = focusFactsReadable,
        )

        if (binding != C1bWindowBinding.EXACT) return
        val childCount = state.readNode("child_count_read_failed") { port.nodeChildCount(work.node) } ?: return
        if (work.isRoot) state.rootChildCount = childCount.takeIf { it in 0..512 }
        if (childCount !in 0..512) {
            state.readError("child_count_invalid")
            return
        }
        val boundedCount = childCount.coerceAtMost(limits.maximumChildrenPerNode)
        if (childCount > limits.maximumChildrenPerNode) state.noteBudgetExhausted()
        val nextAncestors = work.ancestors + work.node
        for (index in 0 until boundedCount) {
            val childAttempt = attempt { port.nodeChild(work.node, index) }
            if (!childAttempt.succeeded) {
                state.readError("child_read_failed")
                continue
            }
            val child = childAttempt.value
            if (child == null) {
                state.readError("child_absent")
                continue
            }
            val ancestorMatch = exactMatchAny(state, child, nextAncestors) ?: continue
            val knownMatch = exactMatchAny(state, child, state.knownNodes) ?: continue
            when {
                ancestorMatch -> state.readError("node_cycle_detected")
                knownMatch -> state.readError("node_duplicate_detected")
                work.depth >= limits.maximumDepth -> state.noteBudgetExhausted()
                else -> {
                    val identity = C1bNodeIdentityToken("${work.identity.value}/$index")
                    state.knownNodes += child
                    state.queue.addLast(NodeWork(child, identity, work.depth + 1, false, nextAncestors))
                }
            }
        }
    }

    private fun exactMatchAny(
        state: MutableWindowState,
        candidate: C1bNodeHandle,
        known: List<C1bNodeHandle>,
    ): Boolean? {
        known.forEach { existing ->
            val comparison = attempt { port.nodesExactlyEqual(candidate, existing) }
            if (!comparison.succeeded) {
                state.readError("node_identity_read_failed")
                return null
            }
            if (comparison.value == true) return true
        }
        return false
    }

    private fun classifyFocus(
        states: List<MutableWindowState>,
        windowsTruncated: Boolean,
        nodesTruncated: Boolean,
        diagnosticCodes: MutableSet<String>,
    ): C1bFocusObservation {
        if (windowsTruncated || nodesTruncated) return C1bFocusObservation(C1bFocusStatus.UNKNOWN, null, null)
        if (states.any { state -> state.type == "application" && !state.hasCompleteFocusTopology }) {
            diagnosticCodes += "focus_inventory_invalid"
            return C1bFocusObservation(C1bFocusStatus.UNKNOWN, null, null)
        }
        if (states.any { state ->
                state.type == "application" &&
                    (!state.windowFocusReadable || state.nodeMetadata.any { !it.focusFactsReadable })
            }
        ) {
            diagnosticCodes += "focus_inventory_invalid"
            return C1bFocusObservation(C1bFocusStatus.UNKNOWN, null, null)
        }
        val focusedWindows = states.filter { it.type == "application" && it.focused }
        val metadata = states.flatMap { state -> state.nodeMetadata.map { state to it } }
        val eligible = metadata.filter { (state, node) ->
            node.isEligibleWechatEditor &&
                state.bounds?.contains(requireNotNull(node.observation.bounds)) == true
        }

        val directAttempt = attempt { port.inputFocusNode() }
        if (!directAttempt.succeeded) {
            diagnosticCodes += "focus_inventory_invalid"
            return C1bFocusObservation(C1bFocusStatus.CONFLICT, null, null)
        }
        val direct = directAttempt.value
        if (direct == null) {
            return when {
                eligible.isNotEmpty() -> C1bFocusObservation(C1bFocusStatus.CONFLICT, null, null)
                focusedWindows.size == 1 -> C1bFocusObservation(
                    C1bFocusStatus.WINDOW_ONLY,
                    focusedWindows.single().windowLabel,
                    null,
                )
                focusedWindows.isEmpty() -> C1bFocusObservation(C1bFocusStatus.ABSENT, null, null)
                else -> C1bFocusObservation(C1bFocusStatus.CONFLICT, null, null)
            }
        }

        val directFacts = readDirectFocus(direct)
        val matches = mutableListOf<Pair<MutableWindowState, NodeMetadata>>()
        metadata.forEach { candidate ->
            val comparison = attempt { port.nodesExactlyEqual(direct, candidate.second.handle) }
            if (!comparison.succeeded) {
                diagnosticCodes += "focus_inventory_invalid"
                return C1bFocusObservation(C1bFocusStatus.CONFLICT, null, null)
            }
            if (comparison.value == true) matches += candidate
        }
        val matched = matches.singleOrNull()
        val exactBinding = matched != null && directFacts.windowId != null &&
            directFacts.windowId == matched.first.rawWindowId &&
            matched.second.observation.windowIdBinding == C1bWindowBinding.EXACT
        val exactGeometry = matched?.second?.observation?.bounds != null &&
            directFacts.bounds == matched.second.observation.bounds &&
            matched.first.bounds?.contains(requireNotNull(directFacts.bounds)) == true
        val directEligible = directFacts.refreshed && directFacts.bounds?.isPositive == true &&
            directFacts.visible && directFacts.enabled && directFacts.editable && directFacts.focused &&
            directFacts.packageName == C1B_WECHAT_PACKAGE && exactBinding && exactGeometry
        if (!directFacts.readable) {
            diagnosticCodes += "focus_inventory_invalid"
            return C1bFocusObservation(C1bFocusStatus.CONFLICT, null, null)
        }
        val isResidual = directFacts.refreshed &&
            (directFacts.bounds?.isPositive != true || !directFacts.focused || !directFacts.editable)
        if (!directEligible && isResidual && eligible.isEmpty()) {
            // Android can retain a refreshed-but-degenerate/non-editor FOCUS_INPUT handle. It is residual inventory,
            // not an editor and not a reason to turn a valid window_only/absent state into an editor claim.
            return when {
                focusedWindows.size == 1 -> C1bFocusObservation(
                    C1bFocusStatus.WINDOW_ONLY,
                    focusedWindows.single().windowLabel,
                    null,
                )
                focusedWindows.isEmpty() -> C1bFocusObservation(C1bFocusStatus.ABSENT, null, null)
                else -> C1bFocusObservation(C1bFocusStatus.CONFLICT, null, null)
            }
        }
        return if (directEligible && matches.size == 1 && eligible.size == 1 &&
            eligible.single() == matched && focusedWindows.size == 1 && focusedWindows.single() == matched.first
        ) {
            C1bFocusObservation(
                C1bFocusStatus.EDITOR_KNOWN,
                matched.first.windowLabel,
                matched.second.nodeLabel,
            )
        } else {
            C1bFocusObservation(C1bFocusStatus.CONFLICT, null, null)
        }
    }

    private fun readDirectFocus(node: C1bNodeHandle): DirectFocusFacts {
        var readable = true
        fun <T> read(block: () -> T): T? {
            val result = attempt(block)
            if (!result.succeeded) readable = false
            return result.value
        }
        val refreshed = read { port.nodeRefresh(node) } == true
        val rawWindowId = read { port.nodeWindowId(node) }
        val windowId = rawWindowId?.takeIf(::c1bIsDefinedWindowId)
        if (rawWindowId != null && windowId == null) readable = false
        val bounds = read { port.nodeBounds(node) }?.takeIf(C1bRect::isSchemaBounded)
        val visible = read { port.nodeVisible(node) } == true
        val enabled = read { port.nodeEnabled(node) } == true
        val editable = read { port.nodeEditable(node) } == true
        val focused = read { port.nodeFocused(node) } == true
        val packageName = read { port.nodePackageName(node) }?.takeIf(C1B_SAFE_ID::matches)
        return DirectFocusFacts(
            readable,
            refreshed,
            windowId,
            bounds,
            visible,
            enabled,
            editable,
            focused,
            packageName,
        )
    }

    private fun captureIme(
        windows: List<C1bWindowObservation>,
        focus: C1bFocusObservation,
        captureToken: String,
        windowInventoryComplete: Boolean,
    ): C1bImeObservation {
        if (!windowInventoryComplete) {
            return C1bImeObservation(false, "unknown", null, "unknown", null, captureToken)
        }
        val imeWindows = windows.filter { it.type == "input_method" }
        if (imeWindows.isEmpty()) {
            return C1bImeObservation(false, "none", null, "not_active", null, captureToken)
        }
        val onlyIme = imeWindows.singleOrNull()
        return C1bImeObservation(
            visible = true,
            mode = "unknown",
            bounds = onlyIme?.bounds,
            binding = if (focus.status == C1bFocusStatus.EDITOR_KNOWN) "editor_known" else "unknown",
            editorNodeLabel = focus.nodeLabel,
            captureToken = captureToken,
        )
    }

    private fun readRevision(code: String): Long = attempt { port.currentRevision() }
        .value?.takeIf { it in 1..Int.MAX_VALUE.toLong() }
        ?: throw IllegalStateException("C1b $code")

    private class MutableWindowState(
        val provisionalIndex: Int,
        val handle: C1bWindowHandle,
        val budgetLimit: Int,
    ) {
        val windowLabel: String = "aw$provisionalIndex"
        var paneLabel: String? = null
        var rawWindowId: Int? = null
        var platformTypeCode: Int = 0
        var type: String = "unknown"
        var displayId: Int = 0
        var layer: Int = -32_768
        var bounds: C1bRect? = null
        var touchableBounds: C1bRect? = null
        var active: Boolean = false
        var focused: Boolean = false
        var windowFocusReadable: Boolean = true
        var expectedWindowTitleMatch: C1bTitleMatchStatus = C1bTitleMatchStatus.NOT_ATTEMPTED
        var rootHandleStatus: C1bRootHandleStatus = C1bRootHandleStatus.UNREADABLE
        var rootPackage: String? = null
        var rootWindowBinding: C1bWindowBinding = C1bWindowBinding.UNKNOWN
        var rootNode: C1bNodeHandle? = null
        var rootIdentity: C1bNodeIdentityToken? = null
        var rootChildCount: Int? = null
        var subtreeStatus: C1bSubtreeStatus? = null
        var subtreeReadErrors: Int = 0
        var budgetUsed: Int = 0
        var budgetExhausted: Boolean = false
        val diagnosticCodes = linkedSetOf<String>()
        val knownNodes = mutableListOf<C1bNodeHandle>()
        val queue = ArrayDeque<NodeWork>()
        val nodes = mutableListOf<C1bNodeObservation>()
        val nodeMetadata = mutableListOf<NodeMetadata>()

        val hasCompleteFocusTopology: Boolean
            get() = rawWindowId != null && bounds?.isPositive == true && windowFocusReadable &&
                rootHandleStatus == C1bRootHandleStatus.READABLE &&
                rootPackage == C1B_WECHAT_PACKAGE && rootWindowBinding == C1bWindowBinding.EXACT &&
                paneLabel != null && subtreeStatus == C1bSubtreeStatus.COMPLETE &&
                rootChildCount != null && subtreeReadErrors == 0 && !budgetExhausted && nodes.isNotEmpty() &&
                nodeMetadata.all(NodeMetadata::focusFactsReadable)

        fun enqueueRoot() {
            val node = requireNotNull(rootNode)
            val identity = requireNotNull(rootIdentity)
            queue.addLast(NodeWork(node, identity, 0, true, emptyList()))
            subtreeStatus = null
        }

        fun <T> read(code: String, block: () -> T): T? {
            val result = attempt(block)
            if (!result.succeeded) structuralError(code)
            return result.value
        }

        fun <T> readNode(code: String, block: () -> T): T? {
            val result = attempt(block)
            if (!result.succeeded) readError(code)
            return result.value
        }

        fun structuralError(code: String) {
            diagnosticCodes += code
        }

        fun readError(code: String) {
            subtreeReadErrors = (subtreeReadErrors + 1).coerceAtMost(MAX_C1B_SUBTREE_READ_ERRORS)
            diagnosticCodes += code
        }

        fun markBudgetExhausted() {
            noteBudgetExhausted()
            queue.clear()
        }

        fun noteBudgetExhausted() {
            budgetExhausted = true
            diagnosticCodes += "node_budget_exhausted"
        }

        fun finishSubtree() {
            if (type != "application") {
                subtreeStatus = C1bSubtreeStatus.NOT_ATTEMPTED
                subtreeReadErrors = 0
                rootChildCount = null
                nodes.clear()
                nodeMetadata.clear()
                return
            }
            if (subtreeStatus == C1bSubtreeStatus.NOT_ATTEMPTED) return
            subtreeStatus = when {
                budgetExhausted -> C1bSubtreeStatus.TRUNCATED
                subtreeReadErrors > 0 -> C1bSubtreeStatus.READ_ERROR
                nodes.isNotEmpty() && rootChildCount != null -> C1bSubtreeStatus.COMPLETE
                else -> C1bSubtreeStatus.READ_ERROR
            }
        }

        fun freeze(): C1bWindowObservation = C1bWindowObservation(
            windowLabel = windowLabel,
            displayId = displayId,
            platformTypeCode = platformTypeCode,
            type = type,
            rootHandleStatus = rootHandleStatus,
            rootPackage = rootPackage,
            rootWindowBinding = rootWindowBinding,
            subtreeCapture = C1bSubtreeObservation(
                status = subtreeStatus ?: C1bSubtreeStatus.READ_ERROR,
                rootChildCount = rootChildCount,
                visitedNodeCount = nodes.size,
                positiveVisibleGeometryNodeCount = nodes.count {
                    it.geometryStatus == C1bGeometryStatus.POSITIVE && it.visible
                },
                focusedEditableNodeCount = nodes.count { it.focused && it.editable },
                readErrorCount = subtreeReadErrors,
                budgetExhausted = budgetExhausted,
            ),
            expectedWindowTitleMatch = expectedWindowTitleMatch,
            layer = layer,
            bounds = bounds,
            touchableBounds = touchableBounds,
            active = active,
            focused = focused,
        )
    }

    private data class NodeWork(
        val node: C1bNodeHandle,
        val identity: C1bNodeIdentityToken,
        val depth: Int,
        val isRoot: Boolean,
        val ancestors: List<C1bNodeHandle>,
    )

    private data class NodeMetadata(
        val identity: C1bNodeIdentityToken,
        val handle: C1bNodeHandle,
        val nodeLabel: String,
        val observation: C1bNodeObservation,
        val packageName: String?,
        val focusFactsReadable: Boolean,
    ) {
        val isEligibleWechatEditor: Boolean
            get() = observation.windowIdBinding == C1bWindowBinding.EXACT &&
                observation.geometryStatus == C1bGeometryStatus.POSITIVE &&
                observation.visible && observation.enabled && observation.editable && observation.focused &&
                packageName == C1B_WECHAT_PACKAGE
    }

    private data class DirectFocusFacts(
        val readable: Boolean,
        val refreshed: Boolean,
        val windowId: Int?,
        val bounds: C1bRect?,
        val visible: Boolean,
        val enabled: Boolean,
        val editable: Boolean,
        val focused: Boolean,
        val packageName: String?,
    )

    private companion object {
        val C1B_INSTANT_FORMATTER = DateTimeFormatterBuilder().appendInstant(7).toFormatter()
    }
}

private fun nodeOrdinal(node: C1bNodeObservation): Int = node.nodeLabel.removePrefix("an").toInt()

/** Android exposes -1 as the undefined window-id sentinel; no negative value is a bindable identity. */
internal fun c1bIsDefinedWindowId(value: Int): Boolean = value >= 0

private data class ReadAttempt<T>(val succeeded: Boolean, val value: T?)

private inline fun <T> attempt(block: () -> T): ReadAttempt<T> = try {
    ReadAttempt(true, block())
} catch (_: Exception) {
    ReadAttempt(false, null)
}

private const val MAX_C1B_SUBTREE_READ_ERRORS = 512
