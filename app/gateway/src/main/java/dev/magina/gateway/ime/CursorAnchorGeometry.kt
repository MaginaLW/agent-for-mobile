package dev.magina.gateway.ime

import android.graphics.RectF
import android.os.Build
import android.view.inputmethod.CursorAnchorInfo
import kotlin.math.abs

internal data class FloatPoint(val x: Float, val y: Float) {
    val isFinite: Boolean get() = x.isFinite() && y.isFinite()
}

internal data class FloatRect(val left: Float, val top: Float, val right: Float, val bottom: Float) {
    val isFinite: Boolean
        get() = left.isFinite() && top.isFinite() && right.isFinite() && bottom.isFinite()
    val isFiniteAndNonEmpty: Boolean
        get() = isFinite && left < right && top < bottom
}

/**
 * 与 Android `android.graphics.Matrix`（SkMatrix 3x3 行主序）完全对齐的纯 Kotlin 仿射矩阵，
 * 用于在 Android 运行时与纯 JVM 单测共用同一套局部坐标 -> 屏幕坐标变换与 fail-closed 校验。
 */
internal class AffineMatrix2D(values: FloatArray) {
    val values: FloatArray = values.copyOf()

    init {
        require(this.values.size == 9) { "Matrix must have 9 elements" }
    }

    val isFinite: Boolean get() = values.all { it.isFinite() }

    /** 与 `android.graphics.Matrix.isAffine()` 对齐：透视行必须为 (0, 0, 1)。 */
    val isAffine: Boolean
        get() = isFinite && values[6] == 0f && values[7] == 0f && values[8] == 1f

    val determinant: Double
        get() = values[0].toDouble() * values[4].toDouble() - values[1].toDouble() * values[3].toDouble()

    /** 仿射且非奇异（可逆）。 */
    val isInvertible: Boolean
        get() = isAffine && determinant.isFinite() && abs(determinant) > 1e-9

    val isIdentity: Boolean
        get() = values[0] == 1f && values[1] == 0f && values[2] == 0f &&
            values[3] == 0f && values[4] == 1f && values[5] == 0f &&
            values[6] == 0f && values[7] == 0f && values[8] == 1f

    fun mapPoint(x: Float, y: Float): FloatPoint? {
        if (!isAffine || !x.isFinite() || !y.isFinite()) return null
        val sx = values[0] * x + values[1] * y + values[2]
        val sy = values[3] * x + values[4] * y + values[5]
        return FloatPoint(sx, sy).takeIf { it.isFinite }
    }

    /** 与 `android.graphics.Matrix.mapRect()` 对齐：映射四角并取轴对齐外包矩形。 */
    fun mapRect(rect: FloatRect): FloatRect? {
        if (!isAffine || !rect.isFiniteAndNonEmpty) return null
        val c1 = mapPoint(rect.left, rect.top) ?: return null
        val c2 = mapPoint(rect.right, rect.top) ?: return null
        val c3 = mapPoint(rect.left, rect.bottom) ?: return null
        val c4 = mapPoint(rect.right, rect.bottom) ?: return null
        val left = minOf(c1.x, c2.x, c3.x, c4.x)
        val top = minOf(c1.y, c2.y, c3.y, c4.y)
        val right = maxOf(c1.x, c2.x, c3.x, c4.x)
        val bottom = maxOf(c1.y, c2.y, c3.y, c4.y)
        return FloatRect(left, top, right, bottom).takeIf { it.isFiniteAndNonEmpty }
    }

    fun origin(): FloatPoint? = mapPoint(0f, 0f)

    companion object {
        fun translation(dx: Float, dy: Float): AffineMatrix2D = AffineMatrix2D(
            floatArrayOf(1f, 0f, dx, 0f, 1f, dy, 0f, 0f, 1f),
        )

        fun scaleAndTranslate(sx: Float, sy: Float, dx: Float, dy: Float): AffineMatrix2D = AffineMatrix2D(
            floatArrayOf(sx, 0f, dx, 0f, sy, dy, 0f, 0f, 1f),
        )

        fun identity(): AffineMatrix2D = translation(0f, 0f)
    }
}

internal enum class CursorUpdateRequestMode(val wireName: String) {
    FILTERED_2ARG("filtered_2arg"),
    LEGACY_1ARG("legacy_1arg"),
    LEGACY_1ARG_AFTER_EMPTY_FILTERED("legacy_1arg_after_empty_filtered"),
}

/**
 * 从 `CursorAnchorInfo` 提取的纯局部几何（不含任何草稿/组合文本/选区文本）。
 * AOSP 契约：`EditorBoundsInfo.editorBounds`、`insertionMarker*`、`visibleLineBounds`
 * 均位于编辑器局部坐标系，经 `CursorAnchorInfo.getMatrix()` 映射至屏幕坐标系。
 */
internal data class RawCursorAnchorData(
    val matrixValues: FloatArray,
    val localEditorBounds: FloatRect? = null,
    val insertionMarkerHorizontal: Float = Float.NaN,
    val insertionMarkerTop: Float = Float.NaN,
    val insertionMarkerBaseline: Float = Float.NaN,
    val insertionMarkerBottom: Float = Float.NaN,
    val insertionMarkerFlags: Int = 0,
    val localVisibleLineBounds: List<FloatRect> = emptyList(),
    val hasMatrix: Boolean = true,
)

internal data class ScreenInsertionMarker(
    val top: FloatPoint,
    val baseline: FloatPoint?,
    val bottom: FloatPoint,
    val flags: Int,
) {
    val hasVisibleRegion: Boolean get() = (flags and FLAG_HAS_VISIBLE_REGION) != 0
    val hasInvisibleRegion: Boolean get() = (flags and FLAG_HAS_INVISIBLE_REGION) != 0
    val isRtl: Boolean get() = (flags and FLAG_IS_RTL) != 0

    val visibility: String
        get() = when {
            hasVisibleRegion && hasInvisibleRegion -> "partially_visible"
            hasVisibleRegion -> "visible"
            hasInvisibleRegion -> "invisible"
            else -> "unspecified"
        }

    fun segmentBounds(): FloatRect = FloatRect(
        left = minOf(top.x, bottom.x),
        top = minOf(top.y, bottom.y),
        right = maxOf(top.x, bottom.x),
        bottom = maxOf(top.y, bottom.y),
    )

    companion object {
        const val FLAG_HAS_VISIBLE_REGION = 1
        const val FLAG_HAS_INVISIBLE_REGION = 2
        const val FLAG_IS_RTL = 4
    }
}

internal data class ScreenCursorAnchorGeometry(
    val fieldId: Int,
    val requestMode: CursorUpdateRequestMode,
    val matrixOrigin: FloatPoint,
    val matrixIsIdentity: Boolean,
    val editorBounds: FloatRect?,
    val insertionMarker: ScreenInsertionMarker?,
    val visibleLineBounds: List<FloatRect>,
    val visibleLineTotalCount: Int,
) {
    val usableInsertionMarker: ScreenInsertionMarker?
        get() = insertionMarker?.takeIf { it.visibility != "invisible" }

    val hasPrimaryGeometry: Boolean
        get() = editorBounds != null || usableInsertionMarker != null || visibleLineBounds.isNotEmpty()
}

private const val MAX_VISIBLE_LINE_BOUNDS = 8

internal fun transformCursorAnchor(
    raw: RawCursorAnchorData,
    fieldId: Int,
    requestMode: CursorUpdateRequestMode,
): ScreenCursorAnchorGeometry? {
    if (!raw.hasMatrix || raw.matrixValues.size != 9) return null
    val matrix = AffineMatrix2D(raw.matrixValues)
    if (!matrix.isInvertible) return null
    val origin = matrix.origin() ?: return null

    val screenEditorBounds = raw.localEditorBounds?.let { local ->
        if (!local.isFiniteAndNonEmpty) null else matrix.mapRect(local)
    }

    val screenMarker = if (
        raw.insertionMarkerHorizontal.isFinite() &&
        raw.insertionMarkerTop.isFinite() &&
        raw.insertionMarkerBottom.isFinite()
    ) {
        val topPt = matrix.mapPoint(raw.insertionMarkerHorizontal, raw.insertionMarkerTop)
        val bottomPt = matrix.mapPoint(raw.insertionMarkerHorizontal, raw.insertionMarkerBottom)
        val baselinePt = if (raw.insertionMarkerBaseline.isFinite()) {
            matrix.mapPoint(raw.insertionMarkerHorizontal, raw.insertionMarkerBaseline)
        } else {
            null
        }
        if (topPt != null && bottomPt != null) {
            ScreenInsertionMarker(topPt, baselinePt, bottomPt, raw.insertionMarkerFlags)
        } else {
            null
        }
    } else {
        null
    }

    val mappedLines = mutableListOf<FloatRect>()
    var validLineCount = 0
    for (localLine in raw.localVisibleLineBounds) {
        if (!localLine.isFiniteAndNonEmpty) continue
        val screenLine = matrix.mapRect(localLine) ?: continue
        validLineCount++
        if (mappedLines.size < MAX_VISIBLE_LINE_BOUNDS) {
            mappedLines += screenLine
        }
    }

    return ScreenCursorAnchorGeometry(
        fieldId = fieldId,
        requestMode = requestMode,
        matrixOrigin = origin,
        matrixIsIdentity = matrix.isIdentity,
        editorBounds = screenEditorBounds,
        insertionMarker = screenMarker,
        visibleLineBounds = mappedLines,
        visibleLineTotalCount = validLineCount,
    )
}

/** 仅读取几何和标志位，不接触 composingText / selection / characterBounds。 */
internal fun extractRawCursorAnchor(info: CursorAnchorInfo): RawCursorAnchorData? {
    val matrix = info.matrix ?: return null
    val values = FloatArray(9)
    matrix.getValues(values)

    val localEditorBounds = if (Build.VERSION.SDK_INT >= 33) {
        info.editorBoundsInfo?.editorBounds?.toFloatRect()
    } else {
        null
    }

    val localLines = if (Build.VERSION.SDK_INT >= 34) {
        info.visibleLineBounds.mapNotNull { it?.toFloatRect() }
    } else {
        emptyList()
    }

    return RawCursorAnchorData(
        matrixValues = values,
        localEditorBounds = localEditorBounds,
        insertionMarkerHorizontal = info.insertionMarkerHorizontal,
        insertionMarkerTop = info.insertionMarkerTop,
        insertionMarkerBaseline = info.insertionMarkerBaseline,
        insertionMarkerBottom = info.insertionMarkerBottom,
        insertionMarkerFlags = info.insertionMarkerFlags,
        localVisibleLineBounds = localLines,
        hasMatrix = true,
    )
}

private fun RectF.toFloatRect(): FloatRect = FloatRect(left, top, right, bottom)
