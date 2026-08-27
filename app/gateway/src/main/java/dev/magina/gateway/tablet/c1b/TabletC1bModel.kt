package dev.magina.gateway.tablet.c1b

import org.json.JSONArray
import org.json.JSONObject
import dev.magina.gateway.tablet.TabletProbeRunContext
import java.time.Duration
import java.time.Instant

internal const val TABLET_C1B_SCHEMA = "tablet-layout-observation/c1b-v1"
internal const val TABLET_C1B_MODE = "c1b_pure_a11y_diagnostic"

/** Pure-value, in-memory identity used only for duplicate defense and two-frame run-local relabeling. */
/**
 * Pure run-local structural path. Android node handles and their 32-bit hash codes never cross the capture boundary.
 * Exact same-frame identity is checked by [TabletC1bReadPort.nodesExactlyEqual].
 */
@JvmInline
internal value class C1bNodeIdentityToken(val value: String) {
    init {
        require(C1B_NODE_PATH.matches(value)) { "C1b node path token is invalid" }
    }
}

private val C1B_NODE_PATH = Regex("r(?:/[0-9]{1,3}){0,128}")

internal data class C1bRect(
    val left: Int,
    val top: Int,
    val right: Int,
    val bottom: Int,
) {
    val width: Int get() = right - left
    val height: Int get() = bottom - top
    val isSchemaBounded: Boolean
        get() = listOf(left, top, right, bottom).all { it in -32_768..32_768 }
    val isPositive: Boolean get() = width > 0 && height > 0
    val isDegenerate: Boolean get() = !isPositive

    fun contains(other: C1bRect): Boolean = isPositive && other.isPositive &&
        other.left >= left && other.top >= top && other.right <= right && other.bottom <= bottom

    fun toJson(): JSONObject = JSONObject()
        .put("left", left)
        .put("top", top)
        .put("right", right)
        .put("bottom", bottom)
}

internal data class C1bDisplayRead(
    val displayId: Int,
    val width: Int,
    val height: Int,
) {
    init {
        require(displayId in 0..16) { "C1b display id is outside the contract range" }
        require(width in 1..16_384 && height in 1..16_384) {
            "C1b display size is outside the contract range"
        }
        require(width != height) { "C1b square display has no closed wire orientation" }
    }

    val orientation: String
        get() = when {
            width > height -> "landscape"
            width < height -> "portrait"
            else -> "square"
        }

    fun toJson(): JSONObject = JSONObject()
        .put("display_id_status", "known")
        .put("display_id", displayId)
        .put("effective_size", JSONObject().put("width", width).put("height", height))
        .put("orientation", orientation)
}

internal enum class C1bRootHandleStatus(val wire: String) {
    READABLE("readable"),
    ABSENT("absent"),
    UNREADABLE("unreadable"),
}

internal enum class C1bWindowBinding(val wire: String) {
    EXACT("exact"),
    MISMATCH("mismatch"),
    UNKNOWN("unknown"),
}

internal enum class C1bSubtreeStatus(val wire: String) {
    COMPLETE("complete"),
    TRUNCATED("truncated"),
    READ_ERROR("read_error"),
    NOT_ATTEMPTED("not_attempted"),
}

internal enum class C1bTitleMatchStatus(val wire: String) {
    MATCH("match"),
    NO_MATCH("no_match"),
    ABSENT("absent"),
    OVER_BUDGET("over_budget"),
    READ_ERROR("read_error"),
    NOT_ATTEMPTED("not_attempted"),
}

internal enum class C1bGeometryStatus(val wire: String) {
    POSITIVE("positive"),
    DEGENERATE("degenerate"),
    UNAVAILABLE("unavailable"),
}

internal enum class C1bFocusStatus(val wire: String) {
    ABSENT("absent"),
    WINDOW_ONLY("window_only"),
    EDITOR_KNOWN("editor_known"),
    CONFLICT("conflict"),
    UNKNOWN("unknown"),
}

internal data class C1bCaptureMetadata(
    val token: String,
    val revisionBefore: Long,
    val revisionAfter: Long,
    val layoutRevision: Long,
    val imeRevision: Long,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("token", token)
        .put("revision_before", revisionBefore)
        .put("revision_after", revisionAfter)
        .put("layout_revision", layoutRevision)
        .put("ime_revision", imeRevision)

    val isAtomic: Boolean
        get() = revisionBefore == revisionAfter &&
            revisionBefore == layoutRevision && revisionBefore == imeRevision &&
            revisionBefore in 1..Int.MAX_VALUE.toLong()
}

internal data class C1bSubtreeObservation(
    val status: C1bSubtreeStatus,
    val rootChildCount: Int?,
    val visitedNodeCount: Int,
    val positiveVisibleGeometryNodeCount: Int,
    val focusedEditableNodeCount: Int,
    val readErrorCount: Int,
    val budgetExhausted: Boolean,
) {
    init {
        require(rootChildCount == null || rootChildCount in 0..512) {
            "C1b root child count is outside the contract range"
        }
        require(visitedNodeCount in 0..512 && positiveVisibleGeometryNodeCount in 0..512 &&
            focusedEditableNodeCount in 0..512 && readErrorCount in 0..512
        ) { "C1b subtree count is outside the contract range" }
        require(positiveVisibleGeometryNodeCount <= visitedNodeCount &&
            focusedEditableNodeCount <= visitedNodeCount
        ) { "C1b subtree derived count exceeds visited inventory" }
    }

    fun toJson(): JSONObject = JSONObject()
        .put("status", status.wire)
        .put("root_child_count", rootChildCount ?: JSONObject.NULL)
        .put("visited_node_count", visitedNodeCount)
        .put("positive_visible_geometry_node_count", positiveVisibleGeometryNodeCount)
        .put("focused_editable_node_count", focusedEditableNodeCount)
        .put("read_error_count", readErrorCount)
        .put("budget_exhausted", budgetExhausted)
}

internal data class C1bWindowObservation(
    val windowLabel: String,
    val displayId: Int,
    val platformTypeCode: Int,
    val type: String,
    val rootHandleStatus: C1bRootHandleStatus,
    val rootPackage: String?,
    val rootWindowBinding: C1bWindowBinding,
    val subtreeCapture: C1bSubtreeObservation,
    val expectedWindowTitleMatch: C1bTitleMatchStatus,
    val layer: Int,
    val bounds: C1bRect?,
    val touchableBounds: C1bRect?,
    val active: Boolean,
    val focused: Boolean,
) {
    init {
        require(displayId in 0..16) { "C1b window display id is outside the contract range" }
        require(platformTypeCode in 0..255) { "C1b platform window type is outside the contract range" }
    }

    fun toJson(): JSONObject = JSONObject()
        .put("window_label", windowLabel)
        .put("identity_namespace", "a11y_run_local")
        .put("display_id", displayId)
        .put("platform_type_code", platformTypeCode)
        .put("type", type)
        .put("root_handle_status", rootHandleStatus.wire)
        .put("root_package", rootPackage ?: JSONObject.NULL)
        .put("root_window_binding", rootWindowBinding.wire)
        .put("subtree_capture", subtreeCapture.toJson())
        .put("expected_window_title_match", expectedWindowTitleMatch.wire)
        .put("layer", layer)
        .put("bounds", bounds?.toJson() ?: JSONObject.NULL)
        .put("touchable_bounds", touchableBounds?.toJson() ?: JSONObject.NULL)
        .put("active", active)
        .put("focused", focused)
}

internal data class C1bPaneObservation(
    val paneLabel: String,
    val windowLabel: String,
    val bounds: C1bRect,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("pane_label", paneLabel)
        .put("window_label", windowLabel)
        .put("bounds", bounds.toJson())
        .put("projection_binding", "root_subtree")
        .put("semantic_role", "unknown")
        .put("semantic_evidence", JSONArray())
}

/**
 * Node wire data is limited to structural facts. It intentionally has no text, description, class, view id,
 * package, content digest, candidate, target, or inferred pane-role field.
 */
internal data class C1bNodeObservation(
    val nodeLabel: String,
    val windowLabel: String,
    val paneLabel: String,
    val isRoot: Boolean,
    val windowIdBinding: C1bWindowBinding,
    val geometryStatus: C1bGeometryStatus,
    val bounds: C1bRect?,
    val visible: Boolean,
    val enabled: Boolean,
    val editable: Boolean,
    val scrollable: Boolean,
    val focused: Boolean,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("node_label", nodeLabel)
        .put("window_label", windowLabel)
        .put("pane_label", paneLabel)
        .put("source", "root_subtree")
        .put("is_root", isRoot)
        .put("window_id_binding", windowIdBinding.wire)
        .put("semantic_role", "unknown")
        .put("geometry_status", geometryStatus.wire)
        .put("bounds", bounds?.toJson() ?: JSONObject.NULL)
        .put("visible", visible)
        .put("enabled", enabled)
        .put("editable", editable)
        .put("scrollable", scrollable)
        .put("focused", focused)
}

internal data class C1bFocusObservation(
    val status: C1bFocusStatus,
    val windowLabel: String?,
    val nodeLabel: String?,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("status", status.wire)
        .put("window_label", windowLabel ?: JSONObject.NULL)
        .put("node_label", nodeLabel ?: JSONObject.NULL)
        .put("source", "a11y_inventory")
}

internal data class C1bImeObservation(
    val visible: Boolean,
    val mode: String,
    val bounds: C1bRect?,
    val binding: String,
    val editorNodeLabel: String?,
    val captureToken: String,
) {
    init {
        require(captureToken == "c1" || captureToken == "c2") {
            "C1b IME capture token is outside the closed frame token set"
        }
    }

    fun toJson(): JSONObject = JSONObject()
        .put("visible", visible)
        .put("mode", mode)
        .put("bounds", bounds?.toJson() ?: JSONObject.NULL)
        .put("binding", binding)
        .put("editor_node_label", editorNodeLabel ?: JSONObject.NULL)
        .put("capture_token", captureToken)
}

/**
 * One raw frame produced directly from the read port. Ephemeral identity maps are in-memory only and are never
 * included by [toJson]; the assembler uses them solely to keep run-local labels stable between c1 and c2.
 */
internal data class C1bRawFrame(
    val captureId: String,
    val capturedAt: String,
    val capture: C1bCaptureMetadata,
    val display: C1bDisplayRead,
    val windows: List<C1bWindowObservation>,
    val windowsTruncated: Boolean,
    val panes: List<C1bPaneObservation>,
    val panesTruncated: Boolean,
    val nodes: List<C1bNodeObservation>,
    val nodesTruncated: Boolean,
    val focus: C1bFocusObservation,
    val ime: C1bImeObservation,
    internal val expectedTitleHash: String,
    internal val windowIdentityTokens: Map<String, Int>,
    internal val nodeIdentityTokens: Map<String, C1bNodeIdentityToken>,
    internal val diagnosticCodes: Set<String>,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("capture_id", captureId)
        .put("captured_at", capturedAt)
        .put("capture", capture.toJson())
        .put("display", display.toJson())
        .put("a11y_windows", windows.map(C1bWindowObservation::toJson).toJsonArray())
        .put("windows_truncated", windowsTruncated)
        .put("panes", panes.map(C1bPaneObservation::toJson).toJsonArray())
        .put("panes_truncated", panesTruncated)
        .put("node_observations", nodes.map(C1bNodeObservation::toJson).toJsonArray())
        .put("nodes_truncated", nodesTruncated)
        .put("focus", focus.toJson())
        .put("ime", ime.toJson())

    override fun toString(): String = toJson().toString()
}

internal data class C1bProvenance(
    val kind: String,
    val name: String,
    val producerCommitSha: String,
    val producerArtifactSha256: String,
) {
    init {
        require(kind == "offline_fixture" || kind == "gateway_runtime_probe")
        require(C1B_SAFE_ID.matches(name))
        require(C1B_GIT_SHA.matches(producerCommitSha))
        require(C1B_STRICT_SHA256.matches(producerArtifactSha256))
    }

    fun toJson(): JSONObject = JSONObject()
        .put("kind", kind)
        .put("name", name)
        .put("version", "c1b-v1")
        .put("producer_commit_sha", producerCommitSha)
        .put("producer_artifact_sha256", producerArtifactSha256)
        .put("runtime_attested", false)
}

internal data class C1bUpstreamT0(
    val sourceKind: String,
    val runId: String,
    val capturedAt: String,
    val artifactSha256: String,
    val producerCommitSha: String,
    val deviceProfileHash: String,
    val readinessReasons: List<String>,
    val p0UnsupportedReasons: List<String>,
) {
    init {
        require(sourceKind == "offline_fixture" || sourceKind == "trusted_runtime")
        require(C1B_SAFE_ID.matches(runId))
        require(C1B_TIMESTAMP.matches(capturedAt))
        require(C1B_STRICT_SHA256.matches(artifactSha256))
        require(C1B_GIT_SHA.matches(producerCommitSha))
        require(C1B_STRICT_SHA256.matches(deviceProfileHash))
        require(readinessReasons.size in 1..64 && readinessReasons.toSet().size == readinessReasons.size)
        require(p0UnsupportedReasons.size in 2..64 &&
            p0UnsupportedReasons.toSet().size == p0UnsupportedReasons.size)
        require(readinessReasons.all(C1B_SAFE_ID::matches))
        require(p0UnsupportedReasons.all(C1B_SAFE_ID::matches))
        require("wechat_layout_unverified" in p0UnsupportedReasons)
        require("tablet_landscape_p0_unimplemented" in p0UnsupportedReasons)
    }

    fun toJson(): JSONObject = JSONObject()
        .put("source_kind", sourceKind)
        .put("schema_version", 5)
        .put("run_id", runId)
        .put("captured_at", capturedAt)
        .put("artifact_sha256", artifactSha256)
        .put("producer_commit_sha", producerCommitSha)
        .put("device_profile_hash", deviceProfileHash)
        .put("intake_status", "accepted")
        .put("readiness_status", "blocked")
        .put("readiness_reasons", readinessReasons.toJsonArray())
        .put("p0_capability", "unsupported")
        .put("p0_unsupported_reasons", p0UnsupportedReasons.toJsonArray())
}

internal data class C1bAssemblyRequest(
    val runId: String,
    val expectedTitleHash: String,
    val provenance: C1bProvenance,
    val upstreamT0: C1bUpstreamT0,
) {
    init {
        require(C1B_SAFE_ID.matches(runId))
        require(C1B_STRICT_SHA256.matches(expectedTitleHash))
    }
}

internal data class C1bConsistency(
    val minimumIntervalMs: Long,
    val stable: Boolean,
    val reasonCodes: List<String>,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("sample_count", 2)
        .put("minimum_interval_ms", minimumIntervalMs)
        .put("stable", stable)
        .put("reason_codes", reasonCodes.toJsonArray())
}

internal data class TabletC1bObservation(
    val runId: String,
    val capturedAt: String,
    val expectedTitleHash: String,
    val provenance: C1bProvenance,
    val upstreamT0: C1bUpstreamT0,
    val frames: List<C1bRawFrame>,
    val consistency: C1bConsistency,
    val reasonCodes: List<String>,
) {
    /** The producer cannot promote topology diagnostics into semantic, layout, action, P0, or execution claims. */
    fun toJson(): JSONObject = JSONObject()
        .put("schema", TABLET_C1B_SCHEMA)
        .put("run_id", runId)
        .put("captured_at", capturedAt)
        .put("mode", TABLET_C1B_MODE)
        .put("expected_title_hash", expectedTitleHash)
        .put("provenance", provenance.toJson())
        .put("upstream_t0", upstreamT0.toJson())
        .put("route", JSONObject()
            .put("kind", "probe_only")
            .put("settings_mutation_allowed", false)
            .put("device_action_allowed", false)
            .put("screenshot_allowed", false)
            .put("ocr_allowed", false))
        .put("privacy", JSONObject()
            .put("hash_algorithm", "sha256")
            .put("raw_window_identity_persisted", false)
            .put("raw_root_identity_persisted", false)
            .put("raw_node_identity_persisted", false)
            .put("window_title_plaintext_persisted", false)
            .put("chat_plaintext_persisted", false)
            .put("chat_content_digest_persisted", false)
            .put("raw_screenshot_persisted", false)
            .put("raw_dump_persisted", false)
            .put("whole_screen_ocr_persisted", false))
        .put("frames", frames.map(C1bRawFrame::toJson).toJsonArray())
        .put("consistency", consistency.toJson())
        .put("diagnostic_status", "blocked")
        .put("reason_codes", reasonCodes.toJsonArray())
        .put("layout_accepted", false)
        .put("wechat_layout_verified", false)
        .put("editor_action_ready", false)
        .put("p0_capability", "unsupported")
        .put("p0_blockers", listOf(
            "tablet_c1b_diagnostic_only",
            "upstream_t0_readiness_blocked",
            "tablet_landscape_p0_unimplemented",
            "tablet_tl2_unverified",
        ).toJsonArray())
        .put("execution_grant", false)

    override fun toString(): String = toJson().toString()
}

internal class TabletC1bAssembler {
    fun assemble(context: TabletProbeRunContext, rawFrames: List<C1bRawFrame>): TabletC1bObservation = assemble(
        C1bAssemblyRequest(
            runId = context.runId,
            expectedTitleHash = context.expectedTitleHash,
            provenance = C1bProvenance(
                kind = context.provenance.kind,
                name = context.provenance.name,
                producerCommitSha = context.provenance.producerCommitSha,
                producerArtifactSha256 = context.provenance.producerArtifactSha256,
            ),
            upstreamT0 = C1bUpstreamT0(
                sourceKind = context.upstreamT0.sourceKind,
                runId = context.upstreamT0.runId,
                capturedAt = context.upstreamT0.capturedAt,
                artifactSha256 = context.upstreamT0.artifactSha256,
                producerCommitSha = context.upstreamT0.producerCommitSha,
                deviceProfileHash = context.upstreamT0.deviceProfileHash,
                readinessReasons = context.upstreamT0.readinessReasons,
                p0UnsupportedReasons = context.upstreamT0.p0UnsupportedReasons,
            ),
        ),
        rawFrames,
    )

    fun assemble(request: C1bAssemblyRequest, rawFrames: List<C1bRawFrame>): TabletC1bObservation {
        require(rawFrames.size == 2) { "C1b requires exactly two raw frames" }
        require(rawFrames.all { it.expectedTitleHash == request.expectedTitleHash }) {
            "C1b frame query hash does not match its assembly request"
        }
        val frames = stabilizeRunLocalLabels(rawFrames)
        val firstAt = Instant.parse(frames[0].capturedAt)
        val secondAt = Instant.parse(frames[1].capturedAt)
        val intervalMs = Duration.between(firstAt, secondAt).toMillis()
        require(intervalMs in 900..60_000) { "C1b frame interval is outside the wire range" }

        val consistencyReasons = linkedSetOf<String>()
        if (frames[0].capture.token != "c1" || frames[1].capture.token != "c2" ||
            frames[0].capture.revisionBefore >= frames[1].capture.revisionBefore
        ) {
            consistencyReasons += "capture_order_invalid"
        }
        if (frames.any { !it.capture.isAtomic }) consistencyReasons += "atomic_capture_revision_invalid"
        if (intervalMs > 15_000) consistencyReasons += "capture_span_exceeded"
        if (frames[0].windows.map { it.windowLabel }.sorted() != frames[1].windows.map { it.windowLabel }.sorted()) {
            consistencyReasons += "window_identity_replacement"
        }
        if (semanticSignature(frames[0]) != semanticSignature(frames[1])) {
            consistencyReasons += "capture_semantics_drift"
        }

        val reasons = linkedSetOf(
            "tablet_layout_diagnostic_only",
            "pane_semantic_roles_unverified",
            "target_conversation_unverified",
            "target_regions_unverified",
        )
        frames.forEach { frame ->
            reasons += deriveFrameReasonCodes(frame)
        }
        reasons += consistencyReasons
        return TabletC1bObservation(
            runId = request.runId,
            capturedAt = frames.last().capturedAt,
            expectedTitleHash = request.expectedTitleHash,
            provenance = request.provenance,
            upstreamT0 = request.upstreamT0,
            frames = frames,
            consistency = C1bConsistency(
                minimumIntervalMs = intervalMs,
                stable = consistencyReasons.isEmpty(),
                reasonCodes = consistencyReasons.sorted(),
            ),
            reasonCodes = reasons.sorted(),
        )
    }

    private fun stabilizeRunLocalLabels(frames: List<C1bRawFrame>): List<C1bRawFrame> {
        val knownWindowLabels = linkedMapOf<Int, String>()
        val knownNodeLabels = linkedMapOf<Pair<Int, C1bNodeIdentityToken>, String>()
        var nextWindow = 1
        var nextNode = 1
        return frames.map { frame ->
            val windowRemap = linkedMapOf<String, String>()
            frame.windows.forEach { window ->
                val token = frame.windowIdentityTokens[window.windowLabel]?.takeIf(::c1bIsDefinedWindowId)
                val label = if (token == null) {
                    "aw${nextWindow++}"
                } else {
                    knownWindowLabels.getOrPut(token) { "aw${nextWindow++}" }
                }
                windowRemap[window.windowLabel] = label
            }
            val paneRemap = linkedMapOf<String, String>()
            frame.panes.forEach { pane ->
                val stableWindow = requireNotNull(windowRemap[pane.windowLabel])
                val suffix = stableWindow.removePrefix("aw")
                paneRemap[pane.paneLabel] = "ap$suffix"
            }
            val nodeRemap = linkedMapOf<String, String>()
            frame.nodes.forEach { node ->
                val windowToken = frame.windowIdentityTokens[node.windowLabel]?.takeIf(::c1bIsDefinedWindowId)
                val nodeToken = frame.nodeIdentityTokens[node.nodeLabel]
                    ?.takeIf { node.windowIdBinding == C1bWindowBinding.EXACT }
                val key = if (windowToken == null || nodeToken == null) null else windowToken to nodeToken
                nodeRemap[node.nodeLabel] = if (key == null) {
                    "an${nextNode++}"
                } else {
                    knownNodeLabels.getOrPut(key) { "an${nextNode++}" }
                }
            }
            frame.relabel(windowRemap, paneRemap, nodeRemap)
        }
    }

    private fun deriveFrameReasonCodes(frame: C1bRawFrame): Set<String> = linkedSetOf<String>().apply {
        if (frame.display.orientation != "landscape") add("not_landscape")
        if (frame.windowsTruncated) add("window_inventory_truncated")
        if (frame.windows.count { it.type == "application" } != 2) add("window_count_not_two")
        frame.windows.forEach { window ->
            if (window.bounds?.isPositive != true || window.touchableBounds?.let { !it.isPositive } == true) {
                add("window_geometry_invalid")
            }
            if (window.displayId != frame.display.displayId) add("multi_display_blocked")
            if (window.type == "unknown" || window.type != c1bPlatformWindowTypeName(window.platformTypeCode)) {
                add("window_type_invalid")
            }
            if (window.type == "application") {
                if (window.rootHandleStatus != C1bRootHandleStatus.READABLE ||
                    window.rootPackage != C1B_WECHAT_PACKAGE
                ) {
                    add("window_root_owner_conflict")
                }
                if (window.rootWindowBinding != C1bWindowBinding.EXACT) add("root_window_binding_invalid")
                if (window.expectedWindowTitleMatch in setOf(
                        C1bTitleMatchStatus.NOT_ATTEMPTED,
                        C1bTitleMatchStatus.OVER_BUDGET,
                        C1bTitleMatchStatus.READ_ERROR,
                    )
                ) {
                    add("window_title_probe_invalid")
                }
                val subtreeIncomplete = window.subtreeCapture.status != C1bSubtreeStatus.COMPLETE ||
                    window.subtreeCapture.rootChildCount == null ||
                    window.subtreeCapture.visitedNodeCount < 1 ||
                    window.subtreeCapture.readErrorCount != 0 ||
                    window.subtreeCapture.budgetExhausted
                if (subtreeIncomplete) {
                    add("subtree_capture_incomplete")
                }
                if (subtreeIncomplete || window.subtreeCapture.positiveVisibleGeometryNodeCount == 0) {
                    add("semantic_subtree_opaque")
                }
            } else if (window.expectedWindowTitleMatch != C1bTitleMatchStatus.NOT_ATTEMPTED) {
                add("window_title_probe_invalid")
            }
        }
        if (frame.panesTruncated) add("pane_projection_invalid")
        val windowsByLabel = frame.windows.associateBy { it.windowLabel }
        val panesByLabel = frame.panes.associateBy { it.paneLabel }
        if (frame.panes.any { pane ->
                val window = windowsByLabel[pane.windowLabel]
                window == null || window.type != "application" || pane.bounds != window.bounds
            }
        ) {
            add("pane_projection_invalid")
        }
        val paneCountByWindow = frame.panes.groupingBy { it.windowLabel }.eachCount()
        if (frame.panes.size != 2 || frame.windows.filter { it.type == "application" }
                .any { paneCountByWindow[it.windowLabel] != 1 }
        ) {
            add("window_root_projection_invalid")
        }
        if (frame.nodesTruncated) add("subtree_capture_incomplete")
        if (frame.nodesTruncated) add("semantic_subtree_opaque")
        if (frame.nodes.any { node ->
                val window = windowsByLabel[node.windowLabel]
                val pane = panesByLabel[node.paneLabel]
                val geometryValid = when (node.geometryStatus) {
                    C1bGeometryStatus.POSITIVE -> node.bounds != null && window?.bounds?.contains(node.bounds) == true
                    C1bGeometryStatus.DEGENERATE -> node.bounds?.isDegenerate == true
                    C1bGeometryStatus.UNAVAILABLE -> node.bounds == null
                }
                window == null || pane?.windowLabel != node.windowLabel ||
                    node.windowIdBinding != C1bWindowBinding.EXACT || !geometryValid
            }
        ) {
            add("node_binding_invalid")
        }
        frame.windows.forEach { window ->
            val windowNodes = frame.nodes.filter { it.windowLabel == window.windowLabel }
            val subtree = window.subtreeCapture
            val countsInvalid = subtree.visitedNodeCount != windowNodes.size ||
                subtree.positiveVisibleGeometryNodeCount != windowNodes.count {
                    it.geometryStatus == C1bGeometryStatus.POSITIVE && it.visible
                } ||
                subtree.focusedEditableNodeCount != windowNodes.count { it.focused && it.editable } ||
                (windowNodes.isNotEmpty() && windowNodes.count { it.isRoot } != 1)
            if (countsInvalid) add("subtree_counts_invalid")
            if (window.type != "application" &&
                (subtree.status != C1bSubtreeStatus.NOT_ATTEMPTED || subtree.rootChildCount != null ||
                    subtree.visitedNodeCount != 0 || subtree.positiveVisibleGeometryNodeCount != 0 ||
                    subtree.focusedEditableNodeCount != 0 || subtree.readErrorCount != 0 ||
                    subtree.budgetExhausted)
            ) {
                add("subtree_counts_invalid")
            }
        }
        if (!focusMatchesWireInventory(frame)) add("focus_inventory_invalid")
        if (!imeMatchesWireInventory(frame)) add("ime_inventory_invalid")
        if (frame.ime.visible) add("ime_hidden_unverified")
    }

    private fun focusMatchesWireInventory(frame: C1bRawFrame): Boolean {
        val applicationTopologyIncomplete = frame.windows.filter { it.type == "application" }.any { window ->
            val windowNodes = frame.nodes.filter { it.windowLabel == window.windowLabel }
            val projectedPanes = frame.panes.filter { it.windowLabel == window.windowLabel }
            val projectedPane = projectedPanes.singleOrNull()
            val nodeInventoryExact = projectedPane != null && windowNodes.all { node ->
                val geometryValid = when (node.geometryStatus) {
                    C1bGeometryStatus.POSITIVE -> node.bounds != null && window.bounds?.contains(node.bounds) == true
                    C1bGeometryStatus.DEGENERATE -> node.bounds?.isDegenerate == true
                    C1bGeometryStatus.UNAVAILABLE -> node.bounds == null
                }
                node.paneLabel == projectedPane.paneLabel &&
                    node.windowIdBinding == C1bWindowBinding.EXACT && geometryValid
            }
            val subtreeCountsExact = window.subtreeCapture.visitedNodeCount == windowNodes.size &&
                window.subtreeCapture.positiveVisibleGeometryNodeCount == windowNodes.count {
                    it.geometryStatus == C1bGeometryStatus.POSITIVE && it.visible
                } &&
                window.subtreeCapture.focusedEditableNodeCount == windowNodes.count { it.focused && it.editable }
            window.rootHandleStatus != C1bRootHandleStatus.READABLE ||
                window.rootPackage != C1B_WECHAT_PACKAGE ||
                window.rootWindowBinding != C1bWindowBinding.EXACT ||
                window.bounds?.isPositive != true ||
                window.subtreeCapture.status != C1bSubtreeStatus.COMPLETE ||
                window.subtreeCapture.rootChildCount == null ||
                window.subtreeCapture.readErrorCount != 0 ||
                window.subtreeCapture.budgetExhausted ||
                windowNodes.isEmpty() || projectedPanes.size != 1 || projectedPane?.bounds != window.bounds ||
                windowNodes.count { it.isRoot } != 1 || !nodeInventoryExact || !subtreeCountsExact
        }
        if (frame.windowsTruncated || frame.nodesTruncated ||
            frame.windows.any { it.type == "unknown" } || applicationTopologyIncomplete
        ) {
            return frame.focus == C1bFocusObservation(C1bFocusStatus.UNKNOWN, null, null)
        }
        val focusedWindows = frame.windows.filter { it.type == "application" && it.focused }
        val editors = frame.nodes.filter {
            it.focused && it.editable && it.visible && it.enabled &&
                it.geometryStatus == C1bGeometryStatus.POSITIVE && it.windowIdBinding == C1bWindowBinding.EXACT
        }
        val expected = when {
            focusedWindows.size > 1 || editors.size > 1 -> C1bFocusStatus.CONFLICT
            focusedWindows.size == 1 && editors.size == 1 &&
                focusedWindows.single().windowLabel == editors.single().windowLabel -> C1bFocusStatus.EDITOR_KNOWN
            focusedWindows.size == 1 && editors.isEmpty() -> C1bFocusStatus.WINDOW_ONLY
            focusedWindows.isEmpty() && editors.isEmpty() -> C1bFocusStatus.ABSENT
            else -> C1bFocusStatus.CONFLICT
        }
        if (frame.focus.status != expected) return false
        return when (expected) {
            C1bFocusStatus.WINDOW_ONLY -> frame.focus.windowLabel == focusedWindows.single().windowLabel &&
                frame.focus.nodeLabel == null
            C1bFocusStatus.EDITOR_KNOWN -> frame.focus.windowLabel == focusedWindows.single().windowLabel &&
                frame.focus.nodeLabel == editors.single().nodeLabel
            else -> frame.focus.windowLabel == null && frame.focus.nodeLabel == null
        }
    }

    private fun imeMatchesWireInventory(frame: C1bRawFrame): Boolean {
        if (frame.ime.captureToken != frame.capture.token) return false
        val windowTypeInventoryComplete = !frame.windowsTruncated && frame.windows.all { window ->
            window.type != "unknown" && window.type == c1bPlatformWindowTypeName(window.platformTypeCode)
        }
        if (!windowTypeInventoryComplete) return false
        val imeWindows = frame.windows.filter { it.type == "input_method" }
        return if (!frame.ime.visible) {
            imeWindows.isEmpty() && frame.ime.mode == "none" && frame.ime.bounds == null &&
                frame.ime.binding == "not_active" && frame.ime.editorNodeLabel == null
        } else {
            imeWindows.size == 1 && frame.ime.bounds == imeWindows.single().bounds
        }
    }

    private fun semanticSignature(frame: C1bRawFrame): String = JSONObject()
        .put("display", frame.display.toJson())
        .put("windows", frame.windows.sortedBy { it.windowLabel }.map(C1bWindowObservation::toJson).toJsonArray())
        .put("windows_truncated", frame.windowsTruncated)
        .put("panes", frame.panes.sortedBy { it.paneLabel }.map(C1bPaneObservation::toJson).toJsonArray())
        .put("panes_truncated", frame.panesTruncated)
        .put("nodes", frame.nodes.sortedBy { it.nodeLabel }.map(C1bNodeObservation::toJson).toJsonArray())
        .put("nodes_truncated", frame.nodesTruncated)
        .put("focus", frame.focus.toJson())
        // c1/c2 tokens intentionally differ across frames. Per-frame exact binding is independently
        // recomputed by imeMatchesWireInventory before this drift-only signature omits the token.
        .put("ime", frame.ime.toJson().apply { remove("capture_token") })
        .toString()
}

private fun C1bRawFrame.relabel(
    windowRemap: Map<String, String>,
    paneRemap: Map<String, String>,
    nodeRemap: Map<String, String>,
): C1bRawFrame = copy(
    windows = windows.map { it.copy(windowLabel = requireNotNull(windowRemap[it.windowLabel])) },
    panes = panes.map {
        it.copy(
            paneLabel = requireNotNull(paneRemap[it.paneLabel]),
            windowLabel = requireNotNull(windowRemap[it.windowLabel]),
        )
    },
    nodes = nodes.map {
        it.copy(
            nodeLabel = requireNotNull(nodeRemap[it.nodeLabel]),
            windowLabel = requireNotNull(windowRemap[it.windowLabel]),
            paneLabel = requireNotNull(paneRemap[it.paneLabel]),
        )
    },
    focus = focus.copy(
        windowLabel = focus.windowLabel?.let { requireNotNull(windowRemap[it]) },
        nodeLabel = focus.nodeLabel?.let { requireNotNull(nodeRemap[it]) },
    ),
    ime = ime.copy(editorNodeLabel = ime.editorNodeLabel?.let { requireNotNull(nodeRemap[it]) }),
    windowIdentityTokens = windowIdentityTokens.mapKeys { (label, _) -> requireNotNull(windowRemap[label]) },
    nodeIdentityTokens = nodeIdentityTokens.mapKeys { (label, _) -> requireNotNull(nodeRemap[label]) },
)

/** The raw Android constant is preserved; this compatibility mapping never assigns pane semantics. */
internal fun c1bPlatformWindowTypeName(rawTypeCode: Int): String = when (rawTypeCode) {
    1 -> "application"
    2 -> "input_method"
    3 -> "system"
    4 -> "accessibility_overlay"
    5 -> "split_screen_divider"
    6 -> "magnification_overlay"
    7 -> "window_control"
    else -> "unknown"
}

internal const val C1B_WECHAT_PACKAGE = "com.tencent.mm"
internal val C1B_SAFE_ID = Regex("[a-z0-9][a-z0-9._-]{0,79}")
internal val C1B_STRICT_SHA256 = Regex("sha256:[0-9a-f]{64}")
internal val C1B_GIT_SHA = Regex("[0-9a-f]{40}")
internal val C1B_TIMESTAMP = Regex(
    "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{7}Z",
)

private fun Iterable<*>.toJsonArray(): JSONArray = JSONArray().also { array -> forEach(array::put) }
