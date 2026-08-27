package dev.magina.gateway.tablet

import android.accessibilityservice.AccessibilityService
import android.graphics.Rect
import android.graphics.Region
import android.hardware.display.DisplayManager
import android.util.DisplayMetrics
import android.view.Display
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import java.time.Instant
import java.time.format.DateTimeFormatterBuilder

/**
 * Android 侧单帧只读 adapter。它的依赖面只有 AccessibilityService 的读取 API 与 revision supplier：
 * 没有 performAction、gesture、input、settings、App 生命周期、截图或文件写入能力。
 *
 * 本类故意未接 ToolRegistry/MCP。未来 runner 必须在事件边界调用 [captureSingleFrame]，将两个或以上
 * 原子帧交给 [TabletLayoutProbe.assemble]；这里不 sleep，也不在 Binder/主线程等待下一帧。
 */
internal class AndroidTabletLayoutProbeSource(
    private val service: AccessibilityService,
    private val revisionProvider: () -> Long,
    private val now: () -> Instant = Instant::now,
) {
    fun captureSingleFrame(
        captureId: String,
        captureToken: String,
        expectedTitleHash: String,
    ): RawTabletProbeFrame {
        var readErrors = 0
        var windowsTruncated = false
        val safeExpectedTitleHash = expectedTitleHash.takeIf(::isStrictProbeHash)
        val revisionBefore = revisionProvider()
        val allWindows = runCatching { service.windows.toList() }
            .getOrElse {
                readErrors += 1
                windowsTruncated = true
                emptyList()
            }
        val budget = NodeCaptureBudget(MAX_NODE_OBSERVATIONS)
        val interactiveWindows = allWindows
            .map { window ->
                captureInteractiveWindow(window, budget, safeExpectedTitleHash).also { captured ->
                    readErrors += captured.readErrors
                    if (captured.readErrors > 0) windowsTruncated = true
                }.window
            }
        val layoutRevision = revisionProvider()

        val primaryDisplayId = selectPrimaryDisplayId(
            interactiveWindows.filter { it.type == "application" },
        )
        val display = captureDisplay(primaryDisplayId).also { if (it.second) readErrors += 1 }.first
        val ime = captureIme(allWindows, display).also { readErrors += it.readErrors }.ime
        val imeRevision = revisionProvider()
        val revisionAfter = revisionProvider()

        return RawTabletProbeFrame(
            captureId = captureId,
            capturedAt = PROBE_INSTANT_FORMATTER.format(now()),
            captureToken = captureToken,
            captureExpectedTitleHash = safeExpectedTitleHash,
            revisionBefore = revisionBefore,
            revisionAfter = revisionAfter,
            layoutRevision = layoutRevision,
            imeRevision = imeRevision,
            display = display,
            interactiveWindows = interactiveWindows,
            ime = ime,
            windowsTruncated = windowsTruncated,
            nodesTruncated = budget.truncated,
            readErrors = readErrors + budget.readErrors,
        )
    }

    private fun captureInteractiveWindow(
        window: AccessibilityWindowInfo,
        budget: NodeCaptureBudget,
        expectedTitleHash: String?,
    ): CapturedWindow {
        var errors = 0
        val boundsResult = runCatching { Rect().also(window::getBoundsInScreen).toProbeRect() }
        val rawBounds = boundsResult.getOrNull()
        val bounds = rawBounds?.takeIf { it.isSchemaBounded() }
        val boundsInvalid = boundsResult.isFailure || rawBounds != null && bounds == null
        if (boundsInvalid) errors += 1

        val touchableResult = runCatching {
            Region().let { region ->
                window.getRegionInScreen(region)
                if (region.isEmpty) null else region.bounds.toProbeRect()
            }
        }
        val rawTouchableBounds = touchableResult.getOrNull()
        val touchableBounds = rawTouchableBounds?.takeIf { it.isSchemaBounded() }
        val touchableBoundsInvalid = touchableResult.isFailure ||
            rawTouchableBounds != null && touchableBounds == null
        if (touchableBoundsInvalid) errors += 1

        val rootResult = runCatching { window.root }
        val root = rootResult.getOrNull()
        val rootStatus = when {
            rootResult.isFailure -> ProbeRootStatus.UNREADABLE
            root == null -> ProbeRootStatus.ABSENT
            else -> ProbeRootStatus.READABLE
        }
        if (rootResult.isFailure) errors += 1
        val rootPackage = root?.let { node ->
            runCatching { probeSafePackageName(node.packageName) }
                .getOrElse {
                    errors += 1
                    null
                }
        }
        val windowType = windowTypeName(window.type)
        // 非 application root 只读取窗口级 owner/status；不遍历其节点内容。
        val nodes = if (root == null || windowType != "application" || bounds == null) {
            emptyList()
        } else {
            captureNodes(root, budget, expectedTitleHash)
        }

        return CapturedWindow(
            window = RawTabletWindow(
                rawWindowId = window.id,
                displayId = runCatching { window.displayId }.getOrElse {
                    errors += 1
                    null
                },
                type = windowType,
                rootPackage = rootPackage,
                layer = runCatching { window.layer }.getOrElse {
                    errors += 1
                    -32_768
                },
                bounds = bounds,
                touchableBounds = touchableBounds,
                rootStatus = rootStatus,
                active = runCatching { window.isActive }.getOrElse {
                    errors += 1
                    false
                },
                focused = runCatching { window.isFocused }.getOrElse {
                    errors += 1
                    false
                },
                nodes = nodes,
                geometryInvalid = boundsInvalid || touchableBoundsInvalid,
            ),
            readErrors = errors,
        )
    }

    private fun captureNodes(
        root: AccessibilityNodeInfo,
        budget: NodeCaptureBudget,
        expectedTitleHash: String?,
    ): List<RawTabletNode> {
        val out = mutableListOf<RawTabletNode>()

        fun visit(
            node: AccessibilityNodeInfo,
            depth: Int,
            ancestorBounds: List<ProbeRect>,
            toolbarAncestorBounds: List<ProbeRect>,
        ) {
            if (depth > MAX_NODE_DEPTH) {
                budget.truncated = true
                return
            }
            if (!budget.take()) return

            val captured = runCatching {
                val bounds = Rect().also(node::getBoundsInScreen).toProbeRect()
                require(bounds.isSchemaBounded()) { "a11y node bounds exceed diagnostic schema" }
                val className = probeMaterializeBoundedText(
                    node.className,
                    MAX_A11Y_CLASS_NAME_CHARACTERS,
                ).orEmpty()
                val viewId = probeMaterializeBoundedText(
                    node.viewIdResourceName,
                    MAX_A11Y_VIEW_ID_CHARACTERS,
                ).orEmpty()
                val role = nodeRole(node, className)
                val visible = node.isVisibleToUser
                val enabled = node.isEnabled
                val clickable = node.isClickable
                val longClickable = node.isLongClickable
                val editable = node.isEditable
                val scrollable = node.isScrollable
                val checkable = node.isCheckable
                val focused = node.isFocused
                val toolbarLineage = if (isStaticToolbarClass(className)) {
                    (toolbarAncestorBounds + bounds).takeLast(MAX_ANCESTOR_BOUNDS)
                } else {
                    toolbarAncestorBounds
                }
                var matchesExpectedTitle = false
                if (expectedTitleHash != null) {
                    for (content in listOfNotNull(node.text, node.contentDescription)) {
                        when (probeMatchesExpectedTitle(content, expectedTitleHash)) {
                            ProbeTitleContentMatch.MATCH -> matchesExpectedTitle = true
                            ProbeTitleContentMatch.OVER_BUDGET -> budget.truncated = true
                            ProbeTitleContentMatch.NO_MATCH -> Unit
                        }
                    }
                }
                val structuralFingerprintMaterial = probeRequireBoundedStructuralMaterial(
                    listOf(
                        className,
                        viewId,
                        bounds.left,
                        bounds.top,
                        bounds.right,
                        bounds.bottom,
                        visible,
                        enabled,
                        clickable,
                        longClickable,
                        editable,
                        scrollable,
                        checkable,
                    ).joinToString("|"),
                )
                RawTabletNode(
                    nodePackage = probeSafePackageName(node.packageName),
                    role = role,
                    bounds = bounds,
                    ancestorBounds = ancestorBounds.takeLast(MAX_ANCESTOR_BOUNDS),
                    toolbarAncestorBounds = toolbarLineage,
                    visible = visible,
                    enabled = enabled,
                    clickable = clickable,
                    longClickable = longClickable,
                    editable = editable,
                    scrollable = scrollable,
                    checkable = checkable,
                    focused = focused,
                    matchesExpectedTitle = matchesExpectedTitle,
                    structuralFingerprintMaterial = structuralFingerprintMaterial,
                )
            }.getOrElse {
                budget.readErrors += 1
                budget.truncated = true
                return
            }
            out += captured

            val nextAncestors = (ancestorBounds + captured.bounds).takeLast(MAX_ANCESTOR_BOUNDS)
            val childCount = runCatching { node.childCount }.getOrElse {
                budget.readErrors += 1
                budget.truncated = true
                return
            }
            for (index in 0 until childCount) {
                if (budget.remaining == 0) {
                    budget.truncated = true
                    return
                }
                val childResult = runCatching { node.getChild(index) }
                if (childResult.isFailure) {
                    budget.readErrors += 1
                    budget.truncated = true
                    continue
                }
                val child = childResult.getOrNull()
                if (child == null) {
                    budget.readErrors += 1
                    budget.truncated = true
                } else {
                    visit(child, depth + 1, nextAncestors, captured.toolbarAncestorBounds)
                }
            }
        }

        visit(root, 0, emptyList(), emptyList())
        return out
    }

    private fun captureDisplay(displayId: Int?): Pair<RawProbeDisplay, Boolean> {
        if (displayId == null) return RawProbeDisplay(null, null) to true
        return runCatching {
            val manager = service.getSystemService(DisplayManager::class.java)
            val display = manager?.getDisplay(displayId)
                ?: return@runCatching RawProbeDisplay(displayId, null) to true
            val metrics = DisplayMetrics()
            @Suppress("DEPRECATION")
            display.getRealMetrics(metrics)
            RawProbeDisplay(
                displayId = displayId,
                effectiveSize = ProbeSize(metrics.widthPixels, metrics.heightPixels),
            ) to false
        }.getOrElse { RawProbeDisplay(displayId, null) to true }
    }

    private fun captureIme(
        allWindows: List<AccessibilityWindowInfo>,
        display: RawProbeDisplay,
    ): CapturedIme {
        val imeWindows = allWindows.filter { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD }
        if (imeWindows.isEmpty()) {
            return CapturedIme(RawProbeIme(false, ProbeImeMode.NONE, null), 0)
        }
        var errors = 0
        val boundsResult = runCatching {
            Rect().also(imeWindows.first()::getBoundsInScreen).toProbeRect()
        }
        val rawBounds = boundsResult.getOrNull()
        val bounds = rawBounds?.takeIf { it.isSchemaBounded() }
        if (boundsResult.isFailure || rawBounds != null && bounds == null) errors += 1
        val size = display.effectiveSize
        val mode = when {
            imeWindows.size != 1 || bounds == null || size == null -> ProbeImeMode.UNKNOWN
            bounds.bottom == size.height && bounds.width >= (size.width * 0.8).toInt() -> ProbeImeMode.DOCKED
            else -> ProbeImeMode.FLOATING
        }
        return CapturedIme(RawProbeIme(true, mode, bounds), errors)
    }

    private fun selectPrimaryDisplayId(windows: List<RawTabletWindow>): Int? {
        val ids = windows.mapNotNull { it.displayId }.distinct()
        return when {
            Display.DEFAULT_DISPLAY in ids -> Display.DEFAULT_DISPLAY
            ids.size == 1 -> ids.single()
            else -> null
        }
    }

    private fun nodeRole(node: AccessibilityNodeInfo, className: String): String = when {
        node.isEditable -> "input_editor"
        node.isScrollable -> "message_viewport"
        className.contains("Toolbar", ignoreCase = true) ||
            className.contains("ActionBar", ignoreCase = true) -> "container"
        node.childCount > 0 -> "container"
        else -> "other"
    }

    private fun windowTypeName(type: Int): String = when (type) {
        AccessibilityWindowInfo.TYPE_APPLICATION -> "application"
        AccessibilityWindowInfo.TYPE_INPUT_METHOD -> "input_method"
        AccessibilityWindowInfo.TYPE_ACCESSIBILITY_OVERLAY -> "accessibility_overlay"
        AccessibilityWindowInfo.TYPE_SYSTEM -> "system"
        else -> "unknown"
    }

    private data class CapturedWindow(val window: RawTabletWindow, val readErrors: Int)
    private data class CapturedIme(val ime: RawProbeIme, val readErrors: Int)

    private class NodeCaptureBudget(maximum: Int) {
        var remaining: Int = maximum
            private set
        var truncated: Boolean = false
        var readErrors: Int = 0

        fun take(): Boolean {
            if (remaining <= 0) {
                truncated = true
                return false
            }
            remaining -= 1
            return true
        }
    }

    private companion object {
        const val MAX_NODE_OBSERVATIONS = 512
        const val MAX_NODE_DEPTH = 60
        const val MAX_ANCESTOR_BOUNDS = 12
        val PROBE_INSTANT_FORMATTER = DateTimeFormatterBuilder().appendInstant(7).toFormatter()
    }
}

private fun Rect.toProbeRect(): ProbeRect = ProbeRect(left, top, right, bottom)

internal const val MAX_A11Y_CLASS_NAME_CHARACTERS = 256
internal const val MAX_A11Y_VIEW_ID_CHARACTERS = 256
internal const val MAX_STRUCTURAL_FINGERPRINT_MATERIAL_CHARACTERS = 1_024
private const val MAX_PACKAGE_NAME_CHARACTERS = 80

/** 先查 length，再物化不可信 Binder CharSequence；超限不截断、不读取任何字符。 */
internal fun probeMaterializeBoundedText(value: CharSequence?, maximumCharacters: Int): String? {
    require(maximumCharacters > 0) { "probe text budget must be positive" }
    if (value == null) return null
    require(value.length <= maximumCharacters) { "a11y text exceeds the diagnostic capture budget" }
    return value.toString()
}

internal fun probeSafePackageName(value: CharSequence?): String? =
    probeMaterializeBoundedText(value, MAX_PACKAGE_NAME_CHARACTERS)
        ?.takeIf { it.isNotEmpty() && SAFE_PACKAGE.matches(it) }

internal fun probeRequireBoundedStructuralMaterial(value: String): String {
    require(value.length <= MAX_STRUCTURAL_FINGERPRINT_MATERIAL_CHARACTERS) {
        "a11y structural fingerprint material exceeds the diagnostic capture budget"
    }
    return value
}

private val SAFE_PACKAGE = Regex("[a-z0-9][a-z0-9._-]{0,79}")

private fun isStaticToolbarClass(className: String): Boolean =
    className.contains("Toolbar", ignoreCase = true) ||
        className.contains("ActionBar", ignoreCase = true)
