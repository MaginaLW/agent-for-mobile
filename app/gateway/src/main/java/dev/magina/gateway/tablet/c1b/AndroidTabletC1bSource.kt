package dev.magina.gateway.tablet.c1b

import android.accessibilityservice.AccessibilityService
import android.graphics.Rect
import android.graphics.Region
import android.hardware.display.DisplayManager
import android.util.DisplayMetrics
import android.view.Display
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.text.Normalizer
import java.time.Instant

/** Android adapter for one C1b raw frame. It has no mutation or external-media dependency surface. */
internal class AndroidTabletC1bSource(
    service: AccessibilityService,
    revisionProvider: () -> Long,
    limits: C1bProbeLimits = C1bProbeLimits(),
    now: () -> Instant = Instant::now,
) {
    private val probe = TabletC1bProbe(
        port = AndroidTabletC1bReadPort(service, revisionProvider),
        limits = limits,
        now = now,
    )

    fun captureSingleFrame(
        captureId: String,
        captureToken: String,
        expectedTitleHash: String,
    ): C1bRawFrame = probe.capture(C1bCaptureRequest(captureId, captureToken, expectedTitleHash))
}

private class AndroidTabletC1bReadPort(
    private val service: AccessibilityService,
    private val revisionProvider: () -> Long,
) : TabletC1bReadPort {
    override fun currentRevision(): Long = revisionProvider()

    override fun display(): C1bDisplayRead {
        val current = service.display ?: service.getSystemService(DisplayManager::class.java)
            ?.getDisplay(Display.DEFAULT_DISPLAY)
            ?: error("C1b display unavailable")
        val metrics = DisplayMetrics()
        @Suppress("DEPRECATION")
        current.getRealMetrics(metrics)
        return c1bDisplayFromRealMetrics(current.displayId, metrics.widthPixels, metrics.heightPixels)
    }

    override fun windows(): List<C1bWindowHandle> = service.windows.map(::AndroidC1bWindow)

    override fun windowId(window: C1bWindowHandle): Int = window.androidWindow.id

    override fun platformTypeCode(window: C1bWindowHandle): Int = window.androidWindow.type

    override fun windowDisplayId(window: C1bWindowHandle): Int = window.androidWindow.displayId

    override fun windowLayer(window: C1bWindowHandle): Int = window.androidWindow.layer

    override fun windowBounds(window: C1bWindowHandle): C1bRect =
        Rect().also(window.androidWindow::getBoundsInScreen).toC1bRect()

    override fun windowTouchableBounds(window: C1bWindowHandle): C1bRect? = Region().let { region ->
        window.androidWindow.getRegionInScreen(region)
        region.bounds.takeUnless(Rect::isEmpty)?.toC1bRect()
    }

    override fun windowActive(window: C1bWindowHandle): Boolean = window.androidWindow.isActive

    override fun windowFocused(window: C1bWindowHandle): Boolean = window.androidWindow.isFocused

    override fun windowExpectedTitleMatch(
        window: C1bWindowHandle,
        expectedTitleHash: String,
    ): C1bTitleMatchStatus = c1bMatchWindowTitle(window.androidWindow.title, expectedTitleHash)

    override fun root(window: C1bWindowHandle): C1bNodeHandle? =
        window.androidWindow.root?.let(::AndroidC1bNode)

    override fun nodesExactlyEqual(first: C1bNodeHandle, second: C1bNodeHandle): Boolean =
        first.androidNode == second.androidNode

    override fun nodeRefresh(node: C1bNodeHandle): Boolean = node.androidNode.refresh()

    override fun nodeWindowId(node: C1bNodeHandle): Int = node.androidNode.windowId

    override fun nodePackageName(node: C1bNodeHandle): String? =
        c1bBoundedPackageName(node.androidNode.packageName)

    override fun nodeBounds(node: C1bNodeHandle): C1bRect =
        Rect().also(node.androidNode::getBoundsInScreen).toC1bRect()

    override fun nodeVisible(node: C1bNodeHandle): Boolean = node.androidNode.isVisibleToUser

    override fun nodeEnabled(node: C1bNodeHandle): Boolean = node.androidNode.isEnabled

    override fun nodeEditable(node: C1bNodeHandle): Boolean = node.androidNode.isEditable

    override fun nodeScrollable(node: C1bNodeHandle): Boolean = node.androidNode.isScrollable

    override fun nodeFocused(node: C1bNodeHandle): Boolean = node.androidNode.isFocused

    override fun nodeChildCount(node: C1bNodeHandle): Int = node.androidNode.childCount

    override fun nodeChild(node: C1bNodeHandle, index: Int): C1bNodeHandle? =
        node.androidNode.getChild(index)?.let(::AndroidC1bNode)

    override fun inputFocusNode(): C1bNodeHandle? =
        service.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)?.let(::AndroidC1bNode)

    private val C1bWindowHandle.androidWindow: AccessibilityWindowInfo
        get() = (this as AndroidC1bWindow).value

    private val C1bNodeHandle.androidNode: AccessibilityNodeInfo
        get() = (this as AndroidC1bNode).value
}

private class AndroidC1bWindow(val value: AccessibilityWindowInfo) : C1bWindowHandle {
    override fun toString(): String = "AndroidC1bWindow(value=<redacted>)"
}

private class AndroidC1bNode(val value: AccessibilityNodeInfo) : C1bNodeHandle {
    override fun toString(): String = "AndroidC1bNode(value=<redacted>)"
}

/**
 * Query-bound native window-title comparison. The title and a non-matching digest never leave this function.
 */
internal fun c1bMatchWindowTitle(
    title: CharSequence?,
    expectedTitleHash: String,
): C1bTitleMatchStatus {
    require(C1B_STRICT_SHA256.matches(expectedTitleHash))
    if (title == null) return C1bTitleMatchStatus.ABSENT
    val length = title.length
    if (length > MAX_C1B_WINDOW_TITLE_CHARACTERS) return C1bTitleMatchStatus.OVER_BUDGET
    val materialized = title.subSequence(0, length).toString()
    val canonical = Normalizer.normalize(materialized, Normalizer.Form.NFKC).trim()
    if (canonical.isEmpty()) return C1bTitleMatchStatus.ABSENT
    val canonicalBytes = canonical.toByteArray(StandardCharsets.UTF_8)
    val actual = MessageDigest.getInstance("SHA-256").digest(canonicalBytes)
    val expectedHex = expectedTitleHash.removePrefix("sha256:")
    val expected = ByteArray(32) { index ->
        expectedHex.substring(index * 2, index * 2 + 2).toInt(16).toByte()
    }
    return try {
        if (MessageDigest.isEqual(actual, expected)) {
            C1bTitleMatchStatus.MATCH
        } else {
            C1bTitleMatchStatus.NO_MATCH
        }
    } finally {
        canonicalBytes.fill(0)
        actual.fill(0)
        expected.fill(0)
    }
}

internal fun c1bDisplayFromRealMetrics(displayId: Int, widthPixels: Int, heightPixels: Int): C1bDisplayRead =
    C1bDisplayRead(displayId, widthPixels, heightPixels)

private fun c1bBoundedPackageName(raw: CharSequence?): String? {
    if (raw == null || raw.length !in 1..80) return null
    return raw.subSequence(0, raw.length).toString().takeIf(C1B_SAFE_ID::matches)
}

private fun Rect.toC1bRect(): C1bRect = C1bRect(left, top, right, bottom)

private const val MAX_C1B_WINDOW_TITLE_CHARACTERS = 256
