package dev.magina.gateway.core

/**
 * 发送后验的三态判定。
 *
 * 为什么不是布尔：`performEditorAction` 只要 InputConnection 还活着就返回 true，通道受理
 * **不等于**消息发出去了（2026-07-26 真机实锤：`press_key` 返回 done:true、确认卡也走完了，
 * 而 marker 原封不动躺在输入框里）。所以危险动作的返回值必须由后验决定。
 *
 * 但"判不了"同样不等于"没发出去"。把判不了报成失败会诱导大脑重试，而**重试发送的代价是重复发送**
 * ——这是比谎报成功更难收拾的一类错。第三态就是为这件事存在的：
 *
 * - [SENT]        有据可判**已发送**：动作成功。
 * - [NOT_SENT]    有据可判**未发送**：动作失败，且不可重试（内容还在框里，人来决定下一步）。
 * - [UNVERIFIED]  **判不了**：动作按成功返回，但明确告诉调用方"没有发送证据"，
 *                 下一步只能是**只读**复核会话最后一条消息，绝不是再按一次 Enter。
 */
enum class SendVerification { SENT, NOT_SENT, UNVERIFIED }

data class SendVerdict(
    val state: SendVerification,
    /** 判据来自哪条腿：a11y / ocr / none。进信封与审计，事后能分辨这次判定有多可信。 */
    val channel: String,
    val detail: String,
)

/**
 * 纯 Kotlin 判定，不碰 Android。两条腿分开写是因为它们的可信度天差地别：
 * a11y 读的是输入框的真实文本，OCR 读的是屏幕底部一条像素带的识别结果。
 */
object SendVerdictPolicy {

    /** 少于这么多字符的基线不足以判断"内容是否消失"（OCR 在空输入栏上也会捡到一两个符号）。 */
    const val MIN_PROBE_CHARS = 4

    /**
     * a11y 腿：拿得到输入框可读文本时的判据。
     *
     * 只有**空**才算已发送，**逐字相同**才算未发送；两者之外（内容变成了别的东西）一律判不了，
     * 不猜。调用方必须在 `text` 为 null 时改走 OCR 腿——null 表示"这个节点没有 text 属性可读"，
     * 不表示"框里是空的"，把它当清空会造出假的发送成功。
     */
    fun fromAccessibilityText(committed: InputCommitEvidence?, text: String): SendVerdict {
        if (committed == null) {
            return SendVerdict(SendVerification.UNVERIFIED, "a11y", "没有已提交文本证据可作基线")
        }
        return when {
            text.isBlank() ->
                SendVerdict(SendVerification.SENT, "a11y", "输入框已清空")
            committed.matchesReadableText(text) ->
                SendVerdict(SendVerification.NOT_SENT, "a11y", "输入框仍逐字保留已提交内容")
            else ->
                SendVerdict(
                    SendVerification.UNVERIFIED, "a11y",
                    "输入框内容既非空也不等于已提交内容（长度=${text.length}）",
                )
        }
    }

    /**
     * OCR 腿：a11y 不透明时仅剩的判据。
     *
     * 基线必须是**已提交文本的原文**。证据里只有长度 ≤ [InputCommitEvidence.PREVIEW_LIMIT] 时
     * `preview` 才是原文，更长时它是截断加省略号的前缀——拿前缀做 contains 判定在长文本上不成立
     * （输入框会换行/滚动，底部这条带里未必还看得到开头），所以超长一律判不了，而不是判失败。
     *
     * 也绝不能拿"Enter 之前那次 OCR 读回的字符串"当基线：OCR 每次的噪声都不同（实测同一屏读出
     * `") POALLOW-…F20 ) POALLOW-…F2C"` 与 `"POALLOW-…F2C"`），任何一次抖动都会被判成
     * "内容已消失"，也就是**谎报发送成功**（2026-07-26 真机实锤）。
     */
    fun fromOcrReadback(
        committed: InputCommitEvidence?,
        readback: String?,
        normalize: (String) -> String,
    ): SendVerdict {
        if (committed == null) {
            return SendVerdict(SendVerification.UNVERIFIED, "ocr", "没有已提交文本证据可作基线")
        }
        if (committed.length > InputCommitEvidence.PREVIEW_LIMIT) {
            return SendVerdict(
                SendVerification.UNVERIFIED, "ocr",
                "已提交文本 ${committed.length} 字超过预览上限 ${InputCommitEvidence.PREVIEW_LIMIT}，" +
                    "证据里只有截断前缀，OCR 腿无法据此判定",
            )
        }
        val wanted = normalize(committed.preview)
        if (wanted.length < MIN_PROBE_CHARS) {
            return SendVerdict(
                SendVerification.UNVERIFIED, "ocr",
                "归一后的基线只有 ${wanted.length} 字，不足 $MIN_PROBE_CHARS 字",
            )
        }
        val actual = normalize(readback.orEmpty())
        return if (actual.contains(wanted)) {
            SendVerdict(SendVerification.NOT_SENT, "ocr", "输入栏仍显示已提交内容")
        } else {
            SendVerdict(SendVerification.SENT, "ocr", "输入栏已不再显示已提交内容")
        }
    }
}
