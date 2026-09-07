package dev.magina.gateway.core

/** spec §2.4 的三个独立时钟。纯配置，不改变当前安全门的运行时超时。 */
data class IntentApprovalTiming(
    val decisionTimeoutMs: Long = 90_000L,
    val intentTtlMs: Long = 360_000L,
    val retractableForegroundWaitBudgetMs: Long = 300_000L,
) {
    init {
        require(decisionTimeoutMs > 0) { "decisionTimeoutMs 必须大于 0" }
        require(intentTtlMs > 0) { "intentTtlMs 必须大于 0" }
        require(retractableForegroundWaitBudgetMs >= 0) { "前台等待预算不能为负" }
        require(intentTtlMs >= retractableForegroundWaitBudgetMs) { "意图有效期必须覆盖前台等待预算" }
    }

    /** I 级固定不等待；它没有可被误配置成延后执行的参数。 */
    fun foregroundWaitBudgetMs(riskTier: RiskTier): Long = when (riskTier) {
        RiskTier.IRREVERSIBLE -> 0L
        RiskTier.RETRACTABLE -> retractableForegroundWaitBudgetMs
    }

    /**
     * 证据最晚在审批请求创建时就已存在；决策等待也会吃掉证据 TTL。
     * 用减法比较避免两个预算相加溢出；恰好到 TTL 也是过期。
     * 这只是装配下限：实际证据可能更旧，执行前仍必须重读与检查。
     */
    fun requiresEvidenceRebuild(riskTier: RiskTier): Boolean {
        val evidenceTtlMs = minOf(
            InputCommitEvidenceStore.DEFAULT_TTL_MS,
            PreparedTargetEvidenceStore.DEFAULT_TTL_MS,
        )
        return decisionTimeoutMs >= evidenceTtlMs ||
            foregroundWaitBudgetMs(riskTier) >= evidenceTtlMs - decisionTimeoutMs
    }
}

/**
 * 离线装配接缝：直接持有会被调用的真实读回依赖，没有可自报为真的 hasRebuilder 布尔值。
 *
 * 当前无 Android 实现，也没有接到 [SafetyGate]。这里证明的仅是依赖存在和读回摘要相等；
 * 接线时仍须在同一 UI mutation 临界区内安装两处新证据、重跑严格身份链与最终执行复核。
 * [rebuildEvidence] 仅服务送进会话的动作；I 级 ui_action 不调用它，仍沿用逐字段相等路径（spec §2.5）。
 */
class IntentApprovalDependencies(
    val riskTier: RiskTier,
    val timing: IntentApprovalTiming = IntentApprovalTiming(),
    private val evidenceReader: IntentEvidenceReader? = null,
) {
    init {
        require(!timing.requiresEvidenceRebuild(riskTier) || evidenceReader != null) {
            "等待可能到达证据 TTL，必须实际装配目标与内容读回通道"
        }
    }

    /** 每次调用读取两处实际读数，再与意图比较；没有缓存旧的 Rebuilt 结论。 */
    fun rebuildEvidence(intent: ApprovalIntent): EvidenceRebuild {
        if (intent.riskTier != riskTier) return EvidenceRebuild.Unverified("意图档位与装配档位不符")
        val reader = evidenceReader ?: return EvidenceRebuild.Unverified("未装配目标与内容读回通道")
        val readback = try {
            reader.read()
        } catch (_: Exception) {
            // 读回异常可能带完整输入或本机细节，不把异常消息写进审批结论。
            return EvidenceRebuild.Unverified("目标或内容读回通道失败")
        }
        return EvidenceRebuildPolicy.judge(intent, readback)
    }
}
