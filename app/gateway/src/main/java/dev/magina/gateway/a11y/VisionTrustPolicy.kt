package dev.magina.gateway.a11y

/** OCR 元素进入动作链（含 ref 二次识别）的统一最低置信度。 */
internal const val MIN_ACTION_OCR_CONFIDENCE = 0.65f

/**
 * 仅用于"当前处于哪个页面"识别的置信度下限，不用于任何会被点击/输入的目标。
 * 页面级标题文字通常字号小、颜色浅，OCR 置信度实测常落在 0.5~0.65 区间，低于
 * [MIN_ACTION_OCR_CONFIDENCE]（2026-07-23 真机实锤：微信聊天列表顶部「微信」标题
 * 置信度 0.51~0.61）。放宽识别门槛不降低实际点击安全性——任何后续真实点击目标
 * 仍独立走 [MIN_ACTION_OCR_CONFIDENCE] 复核（见 P0StageRefActionValidator.find）。
 */
internal const val MIN_RECOGNITION_OCR_CONFIDENCE = 0.45f

/** 盲点安全区下沿与系统手势条之间留出的余量（物理像素）。 */
internal const val P0_PROBE_BOTTOM_MARGIN_PX = 10

/** 盲点安全区的高度（物理像素）；实测微信输入框高约 120px，取 90 留出上下容错。 */
internal const val P0_PROBE_HEIGHT_PX = 90

/**
 * IME-only 降级链读回输入栏时裁剪的带高（自截图底边向上）。
 * 比盲点带（[P0_PROBE_HEIGHT_PX]）高得多：盲点只需要一个可点的中心，读回必须覆盖整条
 * 输入栏——2026-07-26 真机实测，文字基线落在系统底部 inset **之下**，按盲点带裁会读回 null。
 */
internal const val INPUT_BAR_READBACK_HEIGHT_PX = 260

/**
 * 空白输入框盲点安全区（left, top, right, bottom），纯几何计算、无 Android 依赖，可直接单测。
 *
 * 垂直方向从**系统底部 inset 往上推算**而非按屏幕百分比写死：原实现用 0.84h~0.94h，在
 * 1260×2800 上算出 y=2352~2632，而该机微信输入框实测在 y≈2634~2755——落点整整偏高约
 * 130px，砸在消息列表的聊天壁纸上，永远点不到输入框（2026-07-25 真机截图实测）。按屏幕
 * 比例写死无法适配不同机型的手势条/输入栏高度，锚定 inset 更稳。
 *
 * 水平方向保持 24%~76% 不变：避开左侧语音图标与右侧表情/加号图标。
 *
 * 修正后的副作用是正面的：区域现在真正覆盖输入栏，于是"候选区出现任何可见文字就拒绝盲猜"
 * 那道保护会真正生效——语音模式下的「按住 说话」文字会落进区域并挡下盲点，而此前区域偏高
 * 恰好绕开了这道保护。
 */
internal fun p0FocusProbeRegion(width: Int, height: Int, bottomInset: Int): IntArray {
    val bottom = height - bottomInset - P0_PROBE_BOTTOM_MARGIN_PX
    return intArrayOf(
        (width * 0.24).toInt(),
        bottom - P0_PROBE_HEIGHT_PX,
        (width * 0.76).toInt(),
        bottom,
    )
}
