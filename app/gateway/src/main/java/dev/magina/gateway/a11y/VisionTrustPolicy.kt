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
