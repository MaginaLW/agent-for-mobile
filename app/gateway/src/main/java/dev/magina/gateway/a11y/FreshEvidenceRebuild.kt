package dev.magina.gateway.a11y

import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.EvidenceRebuild
import dev.magina.gateway.core.EvidenceRebuildPolicy
import dev.magina.gateway.core.FocusIdentity
import dev.magina.gateway.core.GatewayError
import dev.magina.gateway.core.IdentitySource
import dev.magina.gateway.core.InputCommitEvidence
import dev.magina.gateway.core.PreparedTargetEvidence
import dev.magina.gateway.core.ApprovalIntent
import dev.magina.gateway.core.RiskTier
import dev.magina.gateway.core.TextNorm
import dev.magina.gateway.ime.ImeSessionIdentity

/** 一次标题读取所依赖的完整 fresh capture 身份；缺任一项都不能产出可落盘证据。 */
internal data class FreshEvidenceCapture(
    val revision: Long,
    val captureRevision: Long,
    val visionGeneration: Long,
    val foregroundWindowId: Int,
    val foregroundKnown: Boolean,
    val foregroundPackage: String,
    val blockingOverlay: Boolean,
)

/** 标题及其截图 proof 的不可变组合，避免调用方只拿走文字、丢掉来源世代。 */
internal data class FreshEvidenceSurface(
    val capture: FreshEvidenceCapture,
    val label: String,
    val source: String,
) {
    val canonicalLabel: String get() = TextNorm.label(label)
}

/** 标题与 focused input 在同一个 active fresh-capture 临界区内读取，不允许拆开重组。 */
internal data class FreshEvidenceReadBundle(
    val surface: FreshEvidenceSurface,
    val input: FreshPreparedInputProof,
    /** a11y 不可读时，从与 [surface] 同一张 Bitmap 的输入栏区域识别；不进入日志/信封。 */
    val inputOcrReadback: String? = null,
) {
    override fun toString(): String =
        "FreshEvidenceReadBundle(surface=$surface, input=$input, " +
            "inputOcrReadback=<${inputOcrReadback?.length ?: -1}字符>)"
}

private data class FreshInputBinding(
    val nodePresent: Boolean,
    val nodeId: String?,
    val imeSessionId: String?,
    val focused: Boolean,
    val editable: Boolean,
    val left: Int,
    val top: Int,
    val right: Int,
    val bottom: Int,
    val readableText: String?,
)

/** Release 重建与 debug recorder 共用的 fail-closed proof 判据。 */
internal object FreshEvidenceRebuildGuard {
    fun captureProblems(
        capture: FreshEvidenceCapture,
        expectedPackage: String? = null,
    ): List<String> = buildList {
        if (capture.captureRevision != capture.revision) add("capture_revision 与 revision 不一致")
        if (capture.visionGeneration <= 0) add("vision_generation 无效")
        if (capture.foregroundWindowId < 0) add("前台窗口 id 无效")
        if (!capture.foregroundKnown || capture.foregroundPackage.isBlank()) add("前台应用身份未知")
        if (expectedPackage != null && capture.foregroundPackage != expectedPackage) {
            add("前台应用包与目标包不一致")
        }
        if (capture.blockingOverlay) add("存在遮挡浮层")
    }

    fun identityOf(proof: FreshPreparedInputProof): FocusIdentity? =
        FocusIdentity.of(proof.nodeId, proof.imeSessionId)

    fun boundsStringOf(proof: FreshPreparedInputProof): String? =
        identityOf(proof)?.takeIf { it.source == IdentitySource.A11Y }?.let {
            "[${proof.left},${proof.top}][${proof.right},${proof.bottom}]"
        }

    fun requireSurface(surface: FreshEvidenceSurface, expectedPackage: String) {
        val problems = captureProblems(surface.capture, expectedPackage).toMutableList()
        if (surface.canonicalLabel.isEmpty()) problems += "标题归一后为空"
        if (problems.isNotEmpty()) stale("重建标题截图 proof 无效：${problems.joinToString("、")}")
    }

    fun requireSameSurface(
        expected: FreshEvidenceSurface,
        current: FreshEvidenceSurface,
        expectedPackage: String,
    ) {
        requireSurface(current, expectedPackage)
        if (
            current.capture.revision != expected.capture.revision ||
            current.capture.foregroundWindowId != expected.capture.foregroundWindowId ||
            current.capture.foregroundPackage != expected.capture.foregroundPackage ||
            current.capture.visionGeneration <= expected.capture.visionGeneration ||
            current.canonicalLabel != expected.canonicalLabel
        ) stale("重建期间 capture revision、窗口、截图世代或会话标题已变化")
    }

    fun requireCurrent(
        capture: FreshEvidenceCapture,
        expectedPackage: String,
        expectedSessionId: String,
        current: FreshClickCurrent,
        session: ImeSessionIdentity?,
    ) {
        val problems = captureProblems(capture, expectedPackage)
        if (problems.isNotEmpty()) {
            stale("重建截图 proof 无效：${problems.joinToString("、")}")
        }
        if (
            current.revision != capture.revision ||
            !current.foregroundKnown ||
            current.windowId != capture.foregroundWindowId ||
            current.packageName != expectedPackage ||
            current.blockingOverlay ||
            session == null || !session.belongsTo(expectedPackage) || session.id != expectedSessionId
        ) stale("重建期间页面、前台窗口、遮挡、目标包或 IME 会话已变化")
    }

    fun requireInput(
        capture: FreshEvidenceCapture,
        expectedSessionId: String,
        proof: FreshPreparedInputProof,
    ) {
        val identity = identityOf(proof)
        val a11yProofValid = if (proof.nodeId != null) {
            proof.nodePresent && proof.focused && proof.editable &&
                proof.right > proof.left && proof.bottom > proof.top
        } else {
            !proof.focused && !proof.editable && proof.readableText == null
        }
        if (
            proof.captureRevision != capture.captureRevision ||
            proof.foregroundWindowId != capture.foregroundWindowId ||
            proof.visionGeneration != capture.visionGeneration ||
            proof.imeSessionId != expectedSessionId || identity == null || !a11yProofValid
        ) stale("重建输入身份没有绑定标题截图的 revision、窗口、vision generation 或 IME 会话")
    }

    fun requireSameInput(expected: FreshPreparedInputProof, current: FreshPreparedInputProof) {
        if (expected.binding() != current.binding()) stale("重建期间 focused input 身份或内容已变化")
    }

    fun requireSameBundleInput(
        expected: FreshEvidenceReadBundle,
        current: FreshEvidenceReadBundle,
    ) {
        requireSameInput(expected.input, current.input)
        // a11y 不可读时，binding 里没有内容；必须再比较两张 fresh Bitmap 各自的输入栏 OCR。
        if (expected.input.readableText == null) {
            val before = TextNorm.ocr(expected.inputOcrReadback.orEmpty())
            val after = TextNorm.ocr(current.inputOcrReadback.orEmpty())
            if (before.isEmpty() || before != after) stale("重建落盘前后同图输入栏 OCR 已变化或不可读")
        }
    }

    private fun FreshPreparedInputProof.binding() = FreshInputBinding(
        nodePresent = nodePresent,
        nodeId = nodeId,
        imeSessionId = imeSessionId,
        focused = focused,
        editable = editable,
        left = left,
        top = top,
        right = right,
        bottom = bottom,
        readableText = readableText,
    )

    private fun stale(message: String): Nothing = throw GatewayError(
        ErrorCode.E_STALE_REF,
        message,
        channel = "vision",
        retryable = false,
    )
}

/**
 * 标题初读之后的生产共享事务边界：重新截图证明会话 surface 没换，再读内容，落盘后再终验。
 * 任一步失败都回滚两份 store；Exception 映射成 Unverified，致命 Error 只清理后继续抛出。
 */
internal object FreshEvidenceRebuildExecutor {
    fun execute(
        initialBundle: FreshEvidenceReadBundle,
        expectedPackage: String,
        expectedSessionId: String,
        readCurrent: () -> FreshClickCurrent,
        readSession: () -> ImeSessionIdentity?,
        readCurrentInput: (FreshEvidenceCapture) -> FreshPreparedInputProof,
        readFreshBundle: () -> FreshEvidenceReadBundle?,
        readEvidence: (FreshEvidenceReadBundle) -> EvidenceRebuild,
        publish: (EvidenceRebuild.Rebuilt, FreshPreparedInputProof) -> Unit,
        rollback: () -> Unit,
    ): EvidenceRebuild {
        var completed = false
        try {
            val initialSurface = initialBundle.surface
            FreshEvidenceRebuildGuard.requireSurface(initialSurface, expectedPackage)
            requireCurrent(initialSurface.capture, expectedPackage, expectedSessionId, readCurrent, readSession)
            val initialInput = initialBundle.input
            FreshEvidenceRebuildGuard.requireInput(initialSurface.capture, expectedSessionId, initialInput)

            // 真正重新采样，不把 initialSurface 的旧字段拿来与自己比较。标题相同之外，
            // revision/window/package 必须不变，vision generation 必须严格前进。
            val finalBundle = readFreshBundle()
                ?: throw GatewayError(
                    ErrorCode.E_STALE_REF,
                    "重建落盘前无法取得第二份 fresh 会话与输入 bundle",
                    channel = "vision",
                    retryable = false,
                )
            val finalSurface = finalBundle.surface
            FreshEvidenceRebuildGuard.requireSameSurface(initialSurface, finalSurface, expectedPackage)
            requireCurrent(finalSurface.capture, expectedPackage, expectedSessionId, readCurrent, readSession)

            val finalInput = finalBundle.input
            FreshEvidenceRebuildGuard.requireInput(finalSurface.capture, expectedSessionId, finalInput)
            FreshEvidenceRebuildGuard.requireSameInput(initialInput, finalInput)

            // finalBundle 已在同一个 active capture 内取得标题、输入身份与 OCR 内容；这里只做
            // 纯判定。随后再复核 live state/input，防止判定与落盘之间漂移。
            val verdict = readEvidence(finalBundle)
            requireCurrent(finalSurface.capture, expectedPackage, expectedSessionId, readCurrent, readSession)
            FreshEvidenceRebuildGuard.requireSameInput(finalInput, readCurrentInput(finalSurface.capture))

            if (verdict is EvidenceRebuild.Rebuilt) {
                publish(verdict, finalInput)
                // 微信类页面可能完全不发内容事件，revision/session/input identity 都可原样不动。
                // 因此写入之后还必须真实取第三张图；仅做 live 字段自比较抓不住同 App 会话切换。
                val postBundle = readFreshBundle()
                    ?: throw GatewayError(
                        ErrorCode.E_STALE_REF,
                        "重建落盘后无法取得第三份 fresh 会话与输入 bundle",
                        channel = "vision",
                        retryable = false,
                    )
                FreshEvidenceRebuildGuard.requireSameSurface(finalSurface, postBundle.surface, expectedPackage)
                requireCurrent(postBundle.surface.capture, expectedPackage, expectedSessionId, readCurrent, readSession)
                FreshEvidenceRebuildGuard.requireInput(postBundle.surface.capture, expectedSessionId, postBundle.input)
                FreshEvidenceRebuildGuard.requireSameBundleInput(finalBundle, postBundle)
                val postVerdict = readEvidence(postBundle)
                if (postVerdict != verdict) throw GatewayError(
                    ErrorCode.E_STALE_REF,
                    "重建落盘后的 fresh 内容不再满足同一批准意图",
                    channel = "vision",
                    retryable = false,
                )
                requireCurrent(postBundle.surface.capture, expectedPackage, expectedSessionId, readCurrent, readSession)
                FreshEvidenceRebuildGuard.requireSameInput(
                    postBundle.input,
                    readCurrentInput(postBundle.surface.capture),
                )
            }
            // 非 Rebuilt 也是失败终态：finally 必须清掉入口可能遗留的旧双证据。
            completed = verdict is EvidenceRebuild.Rebuilt
            return verdict
        } catch (error: Exception) {
            return EvidenceRebuild.Unverified(
                "证据重建期间 fresh proof 已失效或两份证据未能完整落盘（${error.javaClass.simpleName}）",
            )
        } finally {
            // finally 而不是 catch(Throwable)：OOM/ThreadDeath 不会被伪装成普通 Unverified，
            // 但任何非正常退出仍尽力销毁可能已经写成的半份证据。
            if (!completed) rollback()
        }
    }

    private fun requireCurrent(
        capture: FreshEvidenceCapture,
        expectedPackage: String,
        expectedSessionId: String,
        readCurrent: () -> FreshClickCurrent,
        readSession: () -> ImeSessionIdentity?,
    ) = FreshEvidenceRebuildGuard.requireCurrent(
        capture = capture,
        expectedPackage = expectedPackage,
        expectedSessionId = expectedSessionId,
        current = readCurrent(),
        session = readSession(),
    )
}

/**
 * 最终 fresh 会话校验之后准备好的唯一动作。输入 proof 与真正使用的 a11y node 必须由调用方
 * 同时取得；[performOnce] 只能选择并投递一个通道，不能在 false/Exception 后 fallback。
 */
internal data class FreshEnterPreparedAction(
    val input: FreshPreparedInputProof,
    val performOnce: () -> Boolean,
)

/**
 * 危险 Enter 的视觉动作边界。
 *
 * 重建事务的第三帧只能证明“落证据那一刻”仍是获批会话；SafetyGate/context/handler 之间仍有
 * 一个可被同 App 页面切换利用的窗口。因此真正投递前必须再取一份 fresh bundle，并在同一次
 * 调用栈内完成标题、内容、输入身份、前台状态与 IME 会话复核，然后只调用一次 [performOnce]。
 *
 * 任一普通异常或 false 都清空两份证据；致命 Error 不伪装成 E_VERIFY_FAIL，但 finally 仍先
 * 尽力回滚。实际 Android 装配必须保持 service monitor → IME sessionLock 的单向锁序。
 */
internal object FreshEnterActionExecutor {
    fun execute(
        expectedFocusIdentity: FocusIdentity,
        expectedFocusedInputBounds: String?,
        expectedPrepared: PreparedTargetEvidence,
        expectedInput: InputCommitEvidence,
        readFreshBundle: () -> FreshEvidenceReadBundle?,
        readCurrent: () -> FreshClickCurrent,
        readSession: () -> ImeSessionIdentity?,
        prepareAction: (FreshEvidenceCapture) -> FreshEnterPreparedAction,
        rollback: () -> Unit,
    ): Boolean {
        var accepted = false
        try {
            requireExpectedChain(
                expectedFocusIdentity,
                expectedFocusedInputBounds,
                expectedPrepared,
                expectedInput,
            )
            val bundle = readFreshBundle() ?: throw unverified(
                "投递前无法取得最终 fresh 会话与输入 bundle",
            )
            val surface = bundle.surface
            val expectedPackage = expectedPrepared.packageName
            val expectedSessionId = expectedFocusIdentity.imeSessionId
            FreshEvidenceRebuildGuard.requireSurface(surface, expectedPackage)
            FreshEvidenceRebuildGuard.requireInput(surface.capture, expectedSessionId, bundle.input)
            requireExpectedInput(
                bundle.input,
                expectedFocusIdentity,
                expectedFocusedInputBounds,
            )
            requireApprovedEvidence(bundle, expectedPrepared, expectedInput)
            requireCurrent(surface.capture, expectedPackage, expectedSessionId, readCurrent, readSession)

            // Android 侧在这里用同一个真实 node 同时形成 proof 与 a11yAction；proof 不同就绝不
            // 触碰 node。之后再复核 live state，才进入 IME sessionLock 的唯一投递。
            val action = prepareAction(surface.capture)
            FreshEvidenceRebuildGuard.requireInput(surface.capture, expectedSessionId, action.input)
            FreshEvidenceRebuildGuard.requireSameInput(bundle.input, action.input)
            requireCurrent(surface.capture, expectedPackage, expectedSessionId, readCurrent, readSession)
            accepted = action.performOnce()
            return accepted
        } catch (error: GatewayError) {
            throw error
        } catch (error: Exception) {
            throw unverified("最终 fresh 会话验证或唯一投递发生 ${error.javaClass.simpleName}")
        } finally {
            if (!accepted) rollback()
        }
    }

    private fun requireExpectedChain(
        identity: FocusIdentity,
        bounds: String?,
        prepared: PreparedTargetEvidence,
        input: InputCommitEvidence,
    ) {
        if (
            prepared.packageName.isBlank() || prepared.label.isBlank() ||
            prepared.identity != identity || input.identity != identity ||
            prepared.bounds != bounds || !FocusIdentity.boundsConsistent(identity.source, bounds)
        ) stale("最终 Enter 的已复核目标、内容、焦点身份或几何证据链不自洽")
    }

    private fun requireExpectedInput(
        proof: FreshPreparedInputProof,
        expectedIdentity: FocusIdentity,
        expectedBounds: String?,
    ) {
        val identity = FreshEvidenceRebuildGuard.identityOf(proof)
        val bounds = FreshEvidenceRebuildGuard.boundsStringOf(proof)
        if (identity != expectedIdentity || bounds != expectedBounds) {
            stale("最终 fresh 输入身份或几何与已复核证据不一致")
        }
    }

    private fun requireApprovedEvidence(
        bundle: FreshEvidenceReadBundle,
        prepared: PreparedTargetEvidence,
        input: InputCommitEvidence,
    ) {
        val inputChannel = if (bundle.input.readableText != null) {
            EvidenceRebuildPolicy.CHANNEL_A11Y
        } else {
            EvidenceRebuildPolicy.CHANNEL_OCR
        }
        val surfaceChannel = if (bundle.surface.source == EvidenceRebuildPolicy.CHANNEL_A11Y) {
            EvidenceRebuildPolicy.CHANNEL_A11Y
        } else {
            EvidenceRebuildPolicy.CHANNEL_OCR
        }
        val verdict = EvidenceRebuildPolicy.judge(
            intent = ApprovalIntent(
                intentId = "final-enter",
                riskTier = RiskTier.IRREVERSIBLE,
                actionKind = "send",
                targetPackage = prepared.packageName,
                targetLabel = prepared.label,
                contentSha256 = input.sha256,
                contentLength = input.length,
                contentNormalized = input.normalizedText,
                contentPreview = input.preview,
                createdAtMs = input.committedAtMs,
            ),
            readback = bundle.input.readableText ?: bundle.inputOcrReadback,
            channel = inputChannel,
            surfaceLabel = bundle.surface.label,
            normalize = TextNorm::ocr,
            surfaceChannel = surfaceChannel,
        )
        when (verdict) {
            is EvidenceRebuild.Rebuilt -> Unit
            is EvidenceRebuild.Mismatch -> stale("最终 fresh 内容与已批准意图不符：${verdict.reason}")
            is EvidenceRebuild.Unverified -> throw unverified(
                "最终 fresh 标题或内容判不了：${verdict.reason}",
            )
        }
    }

    private fun requireCurrent(
        capture: FreshEvidenceCapture,
        expectedPackage: String,
        expectedSessionId: String,
        readCurrent: () -> FreshClickCurrent,
        readSession: () -> ImeSessionIdentity?,
    ) = FreshEvidenceRebuildGuard.requireCurrent(
        capture = capture,
        expectedPackage = expectedPackage,
        expectedSessionId = expectedSessionId,
        current = readCurrent(),
        session = readSession(),
    )

    private fun stale(message: String): Nothing = throw GatewayError(
        ErrorCode.E_STALE_REF,
        message,
        channel = "safety",
        retryable = false,
        fallback = "按站规收尾，不要重试同一危险动作",
    )

    private fun unverified(message: String) = GatewayError(
        ErrorCode.E_VERIFY_FAIL,
        message,
        channel = "vision",
        retryable = false,
        fallback = "不得重试或切换发送通道；只能只读复核当前会话",
    )
}
