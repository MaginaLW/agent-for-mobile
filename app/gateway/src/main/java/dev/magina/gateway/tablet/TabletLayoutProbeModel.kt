package dev.magina.gateway.tablet

import org.json.JSONArray
import org.json.JSONObject

/**
 * T-L1 v2 的数据面只描述“这一帧看到了什么”。这些 DTO 不能被当成动作票据；所有
 * capability/grant 字段都在 [TabletLayoutObservation] 的序列化边界固定为 false/unsupported。
 */
internal data class ProbeRect(
    val left: Int,
    val top: Int,
    val right: Int,
    val bottom: Int,
) {
    val width: Int get() = right - left
    val height: Int get() = bottom - top

    fun contains(other: ProbeRect): Boolean =
        left <= other.left && top <= other.top && right >= other.right && bottom >= other.bottom

    fun intersects(other: ProbeRect): Boolean =
        left < other.right && other.left < right && top < other.bottom && other.top < bottom

    fun toJson(): JSONObject = JSONObject()
        .put("left", left)
        .put("top", top)
        .put("right", right)
        .put("bottom", bottom)
}

internal fun ProbeRect.isSchemaBounded(): Boolean =
    listOf(left, top, right, bottom).all { it in -32_768..32_768 }

internal data class ProbeSize(val width: Int, val height: Int) {
    fun toJson(): JSONObject = JSONObject().put("width", width).put("height", height)
}

internal enum class ProbeRootStatus(val wire: String) {
    READABLE("readable"),
    ABSENT("absent"),
    UNREADABLE("unreadable"),
}

internal enum class ProbePaneRole(val wire: String) {
    NAVIGATION("navigation"),
    CONVERSATION("conversation"),
    UNKNOWN("unknown"),
}

internal enum class ProbePaneBinding(val wire: String) {
    ROOT_SUBTREE("root_subtree"),
    STRUCTURAL_PARTITION("structural_partition"),
    UNKNOWN("unknown"),
}

internal enum class ProbeImeMode(val wire: String) {
    NONE("none"),
    DOCKED("docked"),
    FLOATING("floating"),
    UNKNOWN("unknown"),
}

/** Raw identity 只活在同一次 run 的内存里；这个类型没有 JSON 序列化函数。 */
internal data class RawTabletWindow(
    val rawWindowId: Int,
    val displayId: Int?,
    val type: String,
    val rootPackage: String?,
    val layer: Int,
    val bounds: ProbeRect?,
    val touchableBounds: ProbeRect?,
    val rootStatus: ProbeRootStatus,
    val active: Boolean,
    val focused: Boolean,
    val nodes: List<RawTabletNode>,
    val geometryInvalid: Boolean = false,
)

/**
 * matchesExpectedTitle 只表示“与 caller 已知 hash 相等”；structuralFingerprintMaterial 只在内存里
 * 参与 run-salted 指纹。两者均不可直接落 evidence。
 */
internal data class RawTabletNode(
    val nodePackage: String?,
    val role: String,
    val bounds: ProbeRect,
    val ancestorBounds: List<ProbeRect>,
    val toolbarAncestorBounds: List<ProbeRect>,
    val visible: Boolean,
    val enabled: Boolean,
    val clickable: Boolean,
    val longClickable: Boolean,
    val editable: Boolean,
    val scrollable: Boolean,
    val checkable: Boolean,
    val focused: Boolean,
    val matchesExpectedTitle: Boolean,
    val structuralFingerprintMaterial: String,
)

internal data class RawProbeDisplay(
    val displayId: Int?,
    val effectiveSize: ProbeSize?,
)

internal data class RawProbeIme(
    val visible: Boolean,
    val mode: ProbeImeMode,
    val bounds: ProbeRect?,
)

/** 单帧读取结果仍含 raw a11y window id，只能交给同进程 assembler。 */
internal data class RawTabletProbeFrame(
    val captureId: String,
    val capturedAt: String,
    val captureToken: String,
    /** 仅内存绑定；证明 matchesExpectedTitle 是按哪个 caller-known hash 采集的。 */
    val captureExpectedTitleHash: String?,
    val revisionBefore: Long,
    val revisionAfter: Long,
    val layoutRevision: Long,
    val imeRevision: Long,
    val display: RawProbeDisplay,
    val interactiveWindows: List<RawTabletWindow>,
    val ime: RawProbeIme,
    val windowsTruncated: Boolean = false,
    val nodesTruncated: Boolean,
    val readErrors: Int,
)

internal data class TabletProbeProvenance(
    val kind: String,
    val name: String,
    val version: String,
    val producerCommitSha: String,
    val producerArtifactSha256: String,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("kind", kind)
        .put("name", name)
        .put("version", version)
        .put("producer_commit_sha", producerCommitSha)
        .put("producer_artifact_sha256", producerArtifactSha256)
        // 当前没有独立 runner attest 通道；producer 自己永远不能把自己升格为可信 runtime。
        .put("runtime_attested", false)
}

internal data class TabletProbeUpstreamT0(
    val sourceKind: String,
    val runId: String,
    val capturedAt: String,
    val artifactSha256: String,
    val producerCommitSha: String,
    val deviceProfileHash: String,
    val readinessReasons: List<String>,
    val p0UnsupportedReasons: List<String>,
) {
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

internal class TabletProbeRunContext(
    val runId: String,
    val expectedTitleHash: String,
    runSalt: ByteArray,
    upstreamT0RawUtf8: ByteArray,
    provenance: TabletProbeProvenance,
    upstreamT0: TabletProbeUpstreamT0,
) {
    private val runSaltSnapshot: ByteArray
    private val upstreamT0RawSnapshot: ByteArray
    internal val upstreamT0Tree: StrictProbeJsonValue.ObjectValue
    val provenance: TabletProbeProvenance
    val upstreamT0: TabletProbeUpstreamT0

    init {
        // 在 copy 前限制 caller 内存，避免一个超大 ByteArray 先被复制再由 assembler 拒绝。
        require(runSalt.size == 32) { "tablet probe run salt must contain exactly 32 bytes" }
        require(upstreamT0.readinessReasons.size in 1..64) {
            "tablet probe upstream readiness reason count is invalid"
        }
        require(upstreamT0.p0UnsupportedReasons.size in 2..64) {
            "tablet probe upstream P0 reason count is invalid"
        }
        require(upstreamT0RawUtf8.size in 1..65_536) {
            "tablet probe upstream T0 artifact size is invalid"
        }
        runSaltSnapshot = runSalt.copyOf()
        upstreamT0RawSnapshot = upstreamT0RawUtf8.copyOf()
        upstreamT0Tree = parseStrictProbeJson(upstreamT0RawSnapshot)
        this.provenance = provenance.copy()
        this.upstreamT0 = upstreamT0.copy(
            readinessReasons = upstreamT0.readinessReasons.toList(),
            p0UnsupportedReasons = upstreamT0.p0UnsupportedReasons.toList(),
        )
    }

    fun copyRunSalt(): ByteArray = runSaltSnapshot.copyOf()
    fun copyUpstreamT0RawUtf8(): ByteArray = upstreamT0RawSnapshot.copyOf()
}

internal data class ProbeCapture(
    val token: String,
    val revisionBefore: Long,
    val revisionAfter: Long,
    val layoutRevision: Long,
    val imeRevision: Long,
) {
    val atomic: Boolean
        get() = revisionBefore == revisionAfter &&
            revisionBefore == layoutRevision &&
            revisionBefore == imeRevision

    fun toJson(): JSONObject = JSONObject()
        .put("token", token)
        .put("revision_before", revisionBefore)
        .put("revision_after", revisionAfter)
        .put("layout_revision", layoutRevision)
        .put("ime_revision", imeRevision)
}

internal data class ProbeDisplay(
    val displayId: Int?,
    val effectiveSize: ProbeSize?,
) {
    private val orientation: String
        get() = when {
            effectiveSize == null -> "unknown"
            effectiveSize.width > effectiveSize.height -> "landscape"
            effectiveSize.width < effectiveSize.height -> "portrait"
            effectiveSize.width == effectiveSize.height -> "square"
            else -> "unknown"
        }

    fun toJson(): JSONObject = JSONObject()
        .put("display_id_status", if (displayId == null) "unknown" else "known")
        .put("display_id", displayId ?: JSONObject.NULL)
        .put("effective_size", effectiveSize?.toJson() ?: JSONObject.NULL)
        .put("orientation", orientation)
}

internal data class ProbeWindow(
    val windowLabel: String,
    val displayId: Int?,
    val type: String,
    val rootPackage: String?,
    val layer: Int,
    val bounds: ProbeRect?,
    val touchableBounds: ProbeRect?,
    val rootStatus: ProbeRootStatus,
    val active: Boolean,
    val focused: Boolean,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("window_label", windowLabel)
        .put("identity_namespace", "a11y_run_local")
        .put("display_id", displayId ?: JSONObject.NULL)
        .put("type", type)
        .put("root_package", rootPackage ?: JSONObject.NULL)
        .put("layer", layer)
        .put("bounds", bounds?.toJson() ?: JSONObject.NULL)
        .put("touchable_bounds", touchableBounds?.toJson() ?: JSONObject.NULL)
        .put("root_status", rootStatus.wire)
        .put("active", active)
        .put("focused", focused)
}

internal data class ProbePane(
    val paneLabel: String,
    val windowLabel: String,
    val role: ProbePaneRole,
    val bounds: ProbeRect,
    val binding: ProbePaneBinding,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("pane_label", paneLabel)
        .put("window_label", windowLabel)
        .put("role", role.wire)
        .put("bounds", bounds.toJson())
        .put("binding", binding.wire)
}

internal data class ProbeNodeObservation(
    val nodeLabel: String,
    val windowLabel: String,
    val paneLabel: String?,
    val role: String,
    val bounds: ProbeRect,
    val visible: Boolean,
    val enabled: Boolean,
    val clickable: Boolean,
    val longClickable: Boolean,
    val editable: Boolean,
    val scrollable: Boolean,
    val checkable: Boolean,
    val focused: Boolean,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("node_label", nodeLabel)
        .put("window_label", windowLabel)
        .put("pane_label", paneLabel ?: JSONObject.NULL)
        .put("role", role)
        .put("bounds", bounds.toJson())
        .put("visible", visible)
        .put("enabled", enabled)
        .put("clickable", clickable)
        .put("long_clickable", longClickable)
        .put("editable", editable)
        .put("scrollable", scrollable)
        .put("checkable", checkable)
        .put("focused", focused)
}

internal data class ProbeTitleCandidate(
    val candidateLabel: String,
    val nodeLabel: String,
    val labelHash: String,
    val semanticRole: String,
    val windowLabel: String,
    val paneLabel: String,
    val bounds: ProbeRect,
    val captureToken: String,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("candidate_label", candidateLabel)
        .put("node_label", nodeLabel)
        .put("label_hash", labelHash)
        .put("semantic_role", semanticRole)
        .put("source", "a11y_node")
        .put("window_label", windowLabel)
        .put("pane_label", paneLabel)
        .put("bounds", bounds.toJson())
        .put("capture_token", captureToken)
}

internal open class ProbeRegionCandidate(
    val candidateLabel: String,
    val sourceNodeLabels: List<String>,
    val windowLabel: String,
    val paneLabel: String,
    val bounds: ProbeRect,
    val captureToken: String,
) {
    open fun toJson(): JSONObject = JSONObject()
        .put("candidate_label", candidateLabel)
        .put("source_node_labels", sourceNodeLabels.toJsonArray())
        .put("window_label", windowLabel)
        .put("pane_label", paneLabel)
        .put("bounds", bounds.toJson())
        .put("capture_token", captureToken)
}

internal class ProbeInputCandidate(
    candidateLabel: String,
    val nodeLabel: String,
    val nodePackage: String,
    windowLabel: String,
    paneLabel: String,
    bounds: ProbeRect,
    captureToken: String,
    val editable: Boolean,
    val focused: Boolean,
    val editorFingerprintHash: String,
) : ProbeRegionCandidate(candidateLabel, listOf(nodeLabel), windowLabel, paneLabel, bounds, captureToken) {
    override fun toJson(): JSONObject = super.toJson().also { it.remove("source_node_labels") }
        .put("node_label", nodeLabel)
        .put("node_package", nodePackage)
        .put("editable", editable)
        .put("focused", focused)
        .put("editor_fingerprint_hash", editorFingerprintHash)
}

internal data class ProbeImeObservation(
    val visible: Boolean,
    val mode: ProbeImeMode,
    val bounds: ProbeRect?,
    val editorFingerprintHash: String?,
    val binding: String,
    val targetInputCandidateLabel: String?,
    val captureToken: String,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("visible", visible)
        .put("mode", mode.wire)
        .put("bounds", bounds?.toJson() ?: JSONObject.NULL)
        .put("editor_fingerprint_hash", editorFingerprintHash ?: JSONObject.NULL)
        .put("binding", binding)
        .put("target_input_candidate_label", targetInputCandidateLabel ?: JSONObject.NULL)
        .put("capture_token", captureToken)
}

internal data class ProbeFocusObservation(
    val status: String,
    val windowLabel: String?,
    val inputCandidateLabel: String?,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("status", status)
        .put("window_label", windowLabel ?: JSONObject.NULL)
        .put("input_candidate_label", inputCandidateLabel ?: JSONObject.NULL)
}

internal data class ProbeTargetObservation(
    val expectedTitleHash: String,
    val conversationWindowLabel: String?,
    val conversationPaneLabel: String?,
    val titleCandidates: List<ProbeTitleCandidate>,
    val toolbarCandidates: List<ProbeRegionCandidate>,
    val messageCandidates: List<ProbeRegionCandidate>,
    val inputCandidates: List<ProbeInputCandidate>,
    val focus: ProbeFocusObservation,
    val ime: ProbeImeObservation,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("expected_title_hash", expectedTitleHash)
        .put("conversation_window_label", conversationWindowLabel ?: JSONObject.NULL)
        .put("conversation_pane_label", conversationPaneLabel ?: JSONObject.NULL)
        .put("title_candidates", titleCandidates.map { it.toJson() }.toJsonArray())
        .put("toolbar_candidates", toolbarCandidates.map { it.toJson() }.toJsonArray())
        .put("message_candidates", messageCandidates.map { it.toJson() }.toJsonArray())
        .put("input_candidates", inputCandidates.map { it.toJson() }.toJsonArray())
        .put("focus", focus.toJson())
        .put("ime", ime.toJson())
}

internal data class TabletProbeFrame(
    val captureId: String,
    val capturedAt: String,
    val capture: ProbeCapture,
    val display: ProbeDisplay,
    val windows: List<ProbeWindow>,
    val windowsTruncated: Boolean,
    val panes: List<ProbePane>,
    val panesTruncated: Boolean,
    val nodeObservations: List<ProbeNodeObservation>,
    val nodesTruncated: Boolean,
    val target: ProbeTargetObservation,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("capture_id", captureId)
        .put("captured_at", capturedAt)
        .put("capture", capture.toJson())
        .put("display", display.toJson())
        .put("a11y_windows", windows.map { it.toJson() }.toJsonArray())
        .put("windows_truncated", windowsTruncated)
        .put("panes", panes.map { it.toJson() }.toJsonArray())
        .put("panes_truncated", panesTruncated)
        .put("node_observations", nodeObservations.map { it.toJson() }.toJsonArray())
        .put("nodes_truncated", nodesTruncated)
        .put("target", target.toJson())
}

internal data class ProbeConsistency(
    val sampleCount: Int,
    val minimumIntervalMs: Long,
    val stable: Boolean,
    val reasonCodes: List<String>,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("sample_count", sampleCount)
        .put("minimum_interval_ms", minimumIntervalMs)
        .put("stable", stable)
        .put("reason_codes", reasonCodes.toJsonArray())
}

internal data class TabletLayoutObservation(
    val runId: String,
    val capturedAt: String,
    val provenance: TabletProbeProvenance,
    val upstreamT0: TabletProbeUpstreamT0,
    val frames: List<TabletProbeFrame>,
    val consistency: ProbeConsistency,
    val diagnosticStatus: String,
    val reasonCodes: List<String>,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("schema", "tablet-layout-observation/v2")
        .put("run_id", runId)
        .put("captured_at", capturedAt)
        .put("mode", "diagnostic_only")
        .put("provenance", provenance.toJson())
        .put("upstream_t0", upstreamT0.toJson())
        .put(
            "route",
            JSONObject()
                .put("kind", "probe_only")
                .put("settings_mutation_allowed", false)
                .put("device_action_allowed", false),
        )
        .put(
            "privacy",
            JSONObject()
                .put("hash_algorithm", "sha256")
                .put("raw_window_identity_persisted", false)
                .put("raw_node_identity_persisted", false)
                .put("chat_plaintext_persisted", false)
                .put("raw_screenshot_persisted", false)
                .put("raw_dump_persisted", false)
                .put("whole_screen_ocr_persisted", false),
        )
        .put("frames", frames.map { it.toJson() }.toJsonArray())
        .put("consistency", consistency.toJson())
        .put("diagnostic_status", diagnosticStatus)
        .put("reason_codes", reasonCodes.toJsonArray())
        // 首阶段 producer 没有 runtime attest/validator/runner 闭环，以下常量不可由观测结果翻转。
        .put("layout_accepted", false)
        .put("wechat_layout_verified", false)
        .put("editor_action_ready", false)
        .put("p0_capability", "unsupported")
        .put(
            "p0_blockers",
            listOf(
                "tablet_layout_diagnostic_only",
                "upstream_t0_readiness_blocked",
                "tablet_landscape_p0_unimplemented",
                "tablet_tl2_unverified",
            ).toJsonArray(),
        )
        .put("execution_grant", false)
}

/** 当前没有 ToolRegistry/MCP 接线；这是显式 capability 状态，不是从设备形态推断。 */
internal object TabletLayoutProbeProductionCapability {
    const val available: Boolean = false
    const val runtimeAttested: Boolean = false
    const val actionGrant: Boolean = false
    const val p0Supported: Boolean = false
    const val reason: String = "runtime_runner_not_connected"
}

private fun Iterable<*>.toJsonArray(): JSONArray = JSONArray().also { array -> forEach(array::put) }
