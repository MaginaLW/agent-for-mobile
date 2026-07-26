package dev.magina.gateway.overlay

/** 确认卡在屏幕上的位置与底色；取证时用来判断"这张截图里到底有没有卡"。 */
data class ConfirmCardTarget(
    val left: Int,
    val top: Int,
    val right: Int,
    val bottom: Int,
    val backgroundColor: Int,
)

/**
 * 确认卡取证的可见性判据（纯函数，JVM 可测）。
 *
 * 2026-07-26 Allow 腿实锤：人明明在卡上点了「允许本次」，同一次流程保存下来的
 * `confirmation.png` 里却完全没有卡，只有微信会话页——这张 PNG 因此证明不了
 * "人当时看到了什么"，而它正是监督式跑测唯一的现场证据。截图走的是
 * `AccessibilityService.takeScreenshot`（读的是合成后的显示内容），而 frame commit
 * 回调只保证本进程这一帧提交进管线，SurfaceFlinger 合成/latch 可能还差一两个 vsync。
 *
 * 判据只采卡片左侧内边距那一条竖带：那里除了底色什么都不画（文字与按钮都在
 * padding=48 之内），不会被卡上的白字/橙字/按钮干扰。底色带 alpha（#F2222222），
 * 合成后会被背景透进来一点，所以按通道容差比较而不是精确相等。
 */
fun confirmCardVisibleInCapture(
    target: ConfirmCardTarget,
    width: Int,
    height: Int,
    pixelAt: (x: Int, y: Int) -> Int,
    tolerance: Int = 28,
    minMatchRatio: Double = 0.8,
): Boolean {
    val left = target.left.coerceAtLeast(0)
    val top = target.top.coerceAtLeast(0)
    val right = target.right.coerceAtMost(width)
    val bottom = target.bottom.coerceAtMost(height)
    if (right - left < MIN_CARD_SIDE || bottom - top < MIN_CARD_SIDE) return false

    val xs = (left + 6 until (left + 40).coerceAtMost(right)) step 8
    val rowStep = ((bottom - top) / SAMPLE_ROWS).coerceAtLeast(1)
    val ys = (top + 6 until bottom - 6) step rowStep
    var sampled = 0
    var matched = 0
    for (y in ys) {
        for (x in xs) {
            sampled += 1
            if (channelsWithin(pixelAt(x, y), target.backgroundColor, tolerance)) matched += 1
        }
    }
    if (sampled == 0) return false
    return matched.toDouble() / sampled >= minMatchRatio
}

private fun channelsWithin(actual: Int, expected: Int, tolerance: Int): Boolean {
    for (shift in intArrayOf(16, 8, 0)) {
        val a = (actual shr shift) and 0xFF
        val e = (expected shr shift) and 0xFF
        if (kotlin.math.abs(a - e) > tolerance) return false
    }
    return true
}

/** 比左内边距竖带再窄就没有可靠采样点了，直接判不可信。 */
private const val MIN_CARD_SIDE = 48
private const val SAMPLE_ROWS = 12
