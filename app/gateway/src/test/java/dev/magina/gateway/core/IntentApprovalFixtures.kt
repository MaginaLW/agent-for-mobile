package dev.magina.gateway.core

internal object IntentApprovalFixtures {
    const val CONTENT = "晚点到，先别等我"

    fun intent() = ApprovalIntent(
        intentId = "intent-1",
        riskTier = RiskTier.RETRACTABLE,
        actionKind = "发送消息",
        targetPackage = "com.tencent.mm",
        targetLabel = "文件传输助手",
        contentSha256 = InputCommitEvidence.sha256(CONTENT),
        contentLength = CONTENT.length,
        preview = CONTENT,
        createdAtMs = 1_000,
        ocrBaseline = IntentOcrBaseline.fromContent(CONTENT),
    )

    fun readback() = IntentEvidenceReadback(
        packageName = "com.tencent.mm",
        targetLabel = "文件传输助手",
        content = CONTENT,
        targetChannel = IntentReadbackChannel.A11Y,
        contentChannel = IntentReadbackChannel.A11Y,
    )
}
