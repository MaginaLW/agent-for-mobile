package dev.magina.gateway.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class SafetyGateSemanticIntentTest {

    private val imeSession1 = "ime|0123456789abcdef01234567"
    private val imeSession2 = "ime|fedcba9876543210fedcba98"
    private val nodeId1 = "7|com.tencent.mm:id/chat_input|android.widget.EditText|com.tencent.mm|10,20,100,80"
    private val nodeId2 = "9|com.tencent.mm:id/chat_input_v2|android.widget.EditText|com.tencent.mm|12,24,104,84"
    private val strict1 = FocusIdentity(IdentitySource.A11Y, nodeId1, imeSession1)
    private val strict2 = FocusIdentity(IdentitySource.A11Y, nodeId2, imeSession2)
    private val bounds1 = "[10,20][100,80]"
    private val bounds2 = "[12,24][104,84]"
    private val messageText = "晚点到，先别等我"

    @Test
    fun `retractable enter waits up to 300s rebuilds expired evidence and executes once despite activity and focus drift`() {
        var now = 1_000L
        val inputStore = InputCommitEvidenceStore(ttlMs = 120_000L, clock = { now })
        val preparedStore = PreparedTargetEvidenceStore(ttlMs = 120_000L, clock = { now })
        inputStore.record(messageText, strict1, readbackVerified = true)
        preparedStore.record("文件传输助手", "com.tencent.mm", strict1, bounds1)

        var currentPackage = "com.tencent.mm"
        var currentActivity = ".ui.LauncherUI"
        var currentBootstrapped = false
        var currentIdentity = strict1
        var currentBounds = bounds1
        var readbackReads = 0
        var sleepCount = 0
        var executorCalls = 0
        val auditNotes = ArrayList<String>()

        val gate = createGate(
            now = { now },
            sleep = { ms ->
                sleepCount++
                now += ms
                if (sleepCount == 2) {
                    // 越过 120s 证据 TTL，仍在 300s 前台等待预算与 360s 意图 TTL 内返回微信，
                    // 且 activity、identityBootstrapped、focusIdentity 与 bounds 全部变化。
                    now += 150_000L
                    currentPackage = "com.tencent.mm"
                    currentActivity = ".ui.chatting.ChattingUI"
                    currentBootstrapped = true
                    currentIdentity = strict2
                    currentBounds = bounds2
                }
            },
            inputStore = inputStore,
            preparedStore = preparedStore,
            currentForeground = { currentPackage },
            contextProvider = {
                SafetyContext(
                    packageName = currentPackage,
                    activityName = currentActivity,
                    revision = 10L + sleepCount,
                    foregroundKnown = true,
                    identityBootstrapped = currentBootstrapped,
                    target = SafetyTarget(
                        focusIdentity = currentIdentity,
                        focusedInputBounds = currentBounds,
                        inputCommitEvidence = inputStore.current(currentIdentity),
                        preparedTargetEvidence = preparedStore.current(currentPackage, currentIdentity, currentBounds),
                    ),
                )
            },
            evidenceReader = IntentEvidenceReader {
                readbackReads++
                IntentEvidenceReadback(
                    packageName = currentPackage,
                    targetLabel = "文件传输助手",
                    content = messageText,
                    targetChannel = IntentReadbackChannel.A11Y,
                    contentChannel = IntentReadbackChannel.A11Y,
                )
            },
            liveIdentity = { currentIdentity },
            liveBounds = { currentBounds },
            intentConfirmer = { _, _, cid, nonce ->
                now += 5_000L
                // 批准后切到桌面，再通过 sleep 模拟切回微信。
                currentPackage = "com.android.launcher"
                IntentConfirmationResult(true, ApprovalChannel.OVERLAY, cid, nonce)
            },
            onAuditNote = { auditNotes.add(it) },
        )

        val result = gate.execute("press_key", Level.W, JSONObject().put("key", "enter")) { _, ctx ->
            executorCalls++
            ctx.activityName
        }

        assertEquals(".ui.chatting.ChattingUI", result)
        assertEquals(1, executorCalls)
        assertEquals(1, readbackReads)
        assertTrue(auditNotes.contains("intent_wait=recovered"))
        assertTrue(auditNotes.contains("intent_evidence=rebuilt"))
        assertTrue(auditNotes.contains("intent_match=matched"))
    }

    @Test
    fun `retractable foreground wait timeout fails as stale with zero executor and zero failure record`() {
        var now = 1_000L
        val inputStore = InputCommitEvidenceStore(ttlMs = 120_000L, clock = { now })
        val preparedStore = PreparedTargetEvidenceStore(ttlMs = 120_000L, clock = { now })
        inputStore.record(messageText, strict1, readbackVerified = true)
        preparedStore.record("文件传输助手", "com.tencent.mm", strict1, bounds1)

        var currentPackage = "com.tencent.mm"
        var executorCalls = 0
        var failureRecords = 0
        var staleRecords = 0
        var readbackReads = 0

        val gate = createGate(
            now = { now },
            sleep = { ms -> now += ms },
            inputStore = inputStore,
            preparedStore = preparedStore,
            currentForeground = { currentPackage },
            contextProvider = {
                SafetyContext(
                    packageName = currentPackage,
                    activityName = ".ui.LauncherUI",
                    revision = 1L,
                    foregroundKnown = true,
                    target = SafetyTarget(
                        focusIdentity = strict1,
                        focusedInputBounds = bounds1,
                        inputCommitEvidence = inputStore.current(strict1),
                        preparedTargetEvidence = preparedStore.current("com.tencent.mm", strict1, bounds1),
                    ),
                )
            },
            evidenceReader = IntentEvidenceReader {
                readbackReads++
                IntentApprovalFixtures.readback()
            },
            intentConfirmer = { _, _, cid, nonce ->
                now += 1_000L
                currentPackage = "com.android.launcher"
                IntentConfirmationResult(true, ApprovalChannel.OVERLAY, cid, nonce)
            },
            onExecutionFailure = { failureRecords++ },
            onStaleAfterApproval = { _, _ -> staleRecords++ },
            foregroundPollIntervalMs = 50_000L,
        )

        expectGatewayError(ErrorCode.E_STALE_REF) {
            gate.execute("press_key", Level.W, JSONObject().put("key", "enter")) { _, _ ->
                executorCalls++
            }
        }

        assertEquals(0, executorCalls)
        assertEquals(0, failureRecords)
        assertEquals(1, staleRecords)
        assertEquals(0, readbackReads)
    }

    @Test
    fun `rebuilt mismatch or unverified rejects before executor`() {
        for (tamperedContent in listOf("等待期间被手改的内容", null)) {
            var now = 1_000L
            val inputStore = InputCommitEvidenceStore(ttlMs = 120_000L, clock = { now })
            val preparedStore = PreparedTargetEvidenceStore(ttlMs = 120_000L, clock = { now })
            inputStore.record(messageText, strict1, readbackVerified = true)
            preparedStore.record("文件传输助手", "com.tencent.mm", strict1, bounds1)

            var currentPackage = "com.tencent.mm"
            var executorCalls = 0
            var sleeps = 0

            val gate = createGate(
                now = { now },
                sleep = { ms ->
                    sleeps++
                    now += ms
                    if (sleeps == 1) {
                        now += 140_000L
                        currentPackage = "com.tencent.mm"
                    }
                },
                inputStore = inputStore,
                preparedStore = preparedStore,
                currentForeground = { currentPackage },
                contextProvider = {
                    SafetyContext(
                        packageName = currentPackage,
                        activityName = ".ui.LauncherUI",
                        revision = 1L,
                        foregroundKnown = true,
                        target = SafetyTarget(
                            focusIdentity = strict1,
                            focusedInputBounds = bounds1,
                            inputCommitEvidence = inputStore.current(strict1),
                            preparedTargetEvidence = preparedStore.current("com.tencent.mm", strict1, bounds1),
                        ),
                    )
                },
                evidenceReader = IntentEvidenceReader {
                    IntentEvidenceReadback(
                        packageName = "com.tencent.mm",
                        targetLabel = "文件传输助手",
                        content = tamperedContent,
                        targetChannel = IntentReadbackChannel.A11Y,
                        contentChannel = IntentReadbackChannel.A11Y,
                    )
                },
                intentConfirmer = { _, _, cid, nonce ->
                    currentPackage = "com.android.launcher"
                    IntentConfirmationResult(true, ApprovalChannel.OVERLAY, cid, nonce)
                },
            )

            expectGatewayError(ErrorCode.E_STALE_REF) {
                gate.execute("press_key", Level.W, JSONObject().put("key", "enter")) { _, _ ->
                    executorCalls++
                }
            }
            assertEquals(0, executorCalls)
        }
    }

    @Test
    fun `notification allow channel and missing channel fail closed without execution`() {
        for (channel in listOf(ApprovalChannel.NOTIFICATION, null)) {
            var now = 1_000L
            val inputStore = InputCommitEvidenceStore(ttlMs = 120_000L, clock = { now })
            val preparedStore = PreparedTargetEvidenceStore(ttlMs = 120_000L, clock = { now })
            inputStore.record(messageText, strict1, readbackVerified = true)
            preparedStore.record("文件传输助手", "com.tencent.mm", strict1, bounds1)

            var executorCalls = 0
            var readbackReads = 0
            val gate = createGate(
                now = { now },
                sleep = { now += it },
                inputStore = inputStore,
                preparedStore = preparedStore,
                currentForeground = { "com.tencent.mm" },
                contextProvider = {
                    SafetyContext(
                        packageName = "com.tencent.mm",
                        activityName = ".ui.LauncherUI",
                        revision = 1L,
                        foregroundKnown = true,
                        target = SafetyTarget(
                            focusIdentity = strict1,
                            focusedInputBounds = bounds1,
                            inputCommitEvidence = inputStore.current(strict1),
                            preparedTargetEvidence = preparedStore.current("com.tencent.mm", strict1, bounds1),
                        ),
                    )
                },
                evidenceReader = IntentEvidenceReader {
                    readbackReads++
                    IntentApprovalFixtures.readback()
                },
                intentConfirmer = { _, _, cid, nonce ->
                    IntentConfirmationResult(allowed = true, channel = channel, confirmationId = cid, nonce = nonce)
                },
            )

            expectGatewayError(ErrorCode.E_BLOCKED) {
                gate.execute("press_key", Level.W, JSONObject().put("key", "enter")) { _, _ ->
                    executorCalls++
                }
            }
            assertEquals(0, executorCalls)
            assertEquals(0, readbackReads)
        }
    }

    @Test
    fun `irreversible enter has zero foreground wait budget and irreversible ui_action never triggers session reader`() {
        var now = 1_000L
        val inputStore = InputCommitEvidenceStore(ttlMs = 120_000L, clock = { now })
        val preparedStore = PreparedTargetEvidenceStore(ttlMs = 120_000L, clock = { now })
        inputStore.record("支付密码确认", strict1, readbackVerified = true)
        preparedStore.record("支付密码确认页", "com.tencent.mm", strict1, bounds1)

        var currentPkg = "com.tencent.mm"
        var sleepCount = 0
        var executorCalls = 0
        var readerCalls = 0

        val gate = createGate(
            now = { now },
            sleep = { sleepCount++; now += it },
            inputStore = inputStore,
            preparedStore = preparedStore,
            currentForeground = { currentPkg },
            contextProvider = {
                SafetyContext(
                    packageName = currentPkg,
                    activityName = ".PayUI",
                    revision = 1L,
                    foregroundKnown = true,
                    target = SafetyTarget(
                        focusIdentity = strict1,
                        focusedInputBounds = bounds1,
                        inputCommitEvidence = inputStore.current(strict1),
                        preparedTargetEvidence = preparedStore.current("com.tencent.mm", strict1, bounds1),
                    ),
                )
            },
            evidenceReader = IntentEvidenceReader {
                readerCalls++
                IntentApprovalFixtures.readback()
            },
            intentConfirmer = { _, _, cid, nonce ->
                currentPkg = "com.android.launcher"
                IntentConfirmationResult(true, ApprovalChannel.OVERLAY, cid, nonce)
            },
        )

        expectGatewayError(ErrorCode.E_STALE_REF) {
            gate.execute("press_key", Level.W, JSONObject().put("key", "enter")) { _, _ ->
                executorCalls++
            }
        }
        assertEquals("I 级进入前台等待预算必须为 0", 0, sleepCount)
        assertEquals(0, executorCalls)
        assertEquals(0, readerCalls)

        // I 级 ui_action（「删除」）不触发会话读回，拒绝时 handler=0。
        var deleteExecutors = 0
        val deleteGate = createGate(
            now = { now },
            sleep = { now += it },
            inputStore = inputStore,
            preparedStore = preparedStore,
            currentForeground = { "com.tencent.mm" },
            contextProvider = {
                SafetyContext(
                    packageName = "com.tencent.mm",
                    activityName = ".ui.LauncherUI",
                    revision = 2L,
                    foregroundKnown = true,
                    target = SafetyTarget(ref = "e9", text = "删除", bounds = "[10,20][50,60]", source = "a11y"),
                )
            },
            evidenceReader = IntentEvidenceReader {
                readerCalls++
                IntentApprovalFixtures.readback()
            },
            intentConfirmer = { _, _, cid, nonce ->
                IntentConfirmationResult(false, ApprovalChannel.OVERLAY, cid, nonce)
            },
            legacyConfirmer = { false },
        )
        expectGatewayError(ErrorCode.E_BLOCKED) {
            deleteGate.execute("ui_action", Level.W, JSONObject().put("ref", "e9").put("action", "click")) { _, _ ->
                deleteExecutors++
            }
        }
        assertEquals(0, deleteExecutors)
        assertEquals(0, readerCalls)
    }

    @Test
    fun `missing evidenceReader on long wait fails mechanically before showing confirmation card`() {
        var now = 1_000L
        val inputStore = InputCommitEvidenceStore(ttlMs = 120_000L, clock = { now })
        val preparedStore = PreparedTargetEvidenceStore(ttlMs = 120_000L, clock = { now })
        inputStore.record(messageText, strict1, readbackVerified = true)
        preparedStore.record("文件传输助手", "com.tencent.mm", strict1, bounds1)

        var cardShown = 0
        var executorCalls = 0
        val gate = SafetyGate(
            policy = SafetyPolicy(),
            confirmer = { cardShown++; true },
            contextProvider = {
                SafetyContext(
                    packageName = "com.tencent.mm",
                    activityName = ".ui.LauncherUI",
                    revision = 1L,
                    foregroundKnown = true,
                    target = SafetyTarget(
                        focusIdentity = strict1,
                        focusedInputBounds = bounds1,
                        inputCommitEvidence = inputStore.current(strict1),
                        preparedTargetEvidence = preparedStore.current("com.tencent.mm", strict1, bounds1),
                    ),
                )
            },
            onExecutionFailure = {},
            semanticIntent = SemanticIntentConfig(
                timing = IntentApprovalTiming(),
                dependenciesForTier = { tier ->
                    // 故意不提供 evidenceReader，验证构造即机械阻断且未弹确认卡。
                    IntentApprovalDependencies(tier, IntentApprovalTiming(), evidenceReader = null)
                },
                clock = { now },
                confirmationIdGenerator = { "c-missing-reader" },
                intentConfirmer = { _, _, cid, nonce ->
                    cardShown++
                    IntentConfirmationResult(true, ApprovalChannel.OVERLAY, cid, nonce)
                },
                currentForegroundPackage = { "com.tencent.mm" },
                installRebuiltEvidence = { _, _ -> false },
            ),
        )

        var caught: Throwable? = null
        try {
            gate.execute("press_key", Level.W, JSONObject().put("key", "enter")) { _, _ ->
                executorCalls++
            }
        } catch (t: Throwable) {
            caught = t
        }
        assertTrue(caught is IllegalArgumentException)
        assertEquals(0, cardShown)
        assertEquals(0, executorCalls)
    }

    @Test
    fun `retractable ui_action send supports deferred recovery rebuild and never leaks sensitive audit notes`() {
        var now = 1_000L
        val secretContent = "私密待发消息-7291"
        val inputStore = InputCommitEvidenceStore(ttlMs = 120_000L, clock = { now })
        val preparedStore = PreparedTargetEvidenceStore(ttlMs = 120_000L, clock = { now })
        inputStore.record(secretContent, strict1, readbackVerified = true)
        preparedStore.record("文件传输助手", "com.tencent.mm", strict1, bounds1)

        var currentPkg = "com.tencent.mm"
        var currentIdentity = strict1
        var currentBounds = bounds1
        var currentBtnRef = "e:sess:1:10"
        var currentBtnBounds = "[2000,1800][2150,1900]"
        var sleepCount = 0
        var executorCalls = 0
        val notes = ArrayList<String>()

        val gate = createGate(
            now = { now },
            sleep = { ms ->
                sleepCount++
                now += ms
                if (sleepCount == 1) {
                    now += 150_000L
                    currentPkg = "com.tencent.mm"
                    currentIdentity = strict2
                    currentBounds = bounds2
                    currentBtnRef = "e:sess:2:10"
                    currentBtnBounds = "[2002,1802][2152,1902]"
                }
            },
            inputStore = inputStore,
            preparedStore = preparedStore,
            currentForeground = { currentPkg },
            contextProvider = {
                SafetyContext(
                    packageName = currentPkg,
                    activityName = ".ui.chatting.ChattingUI",
                    revision = 10L + sleepCount,
                    foregroundKnown = true,
                    sameAppMultiWindow = true,
                    target = SafetyTarget(
                        ref = currentBtnRef,
                        text = "发送",
                        description = "",
                        bounds = currentBtnBounds,
                        source = "a11y",
                        focusIdentity = currentIdentity,
                        focusedInputBounds = currentBounds,
                        inputCommitEvidence = inputStore.current(currentIdentity),
                        preparedTargetEvidence = preparedStore.current(currentPkg, currentIdentity, currentBounds),
                        windowPane = "right",
                    ),
                )
            },
            evidenceReader = IntentEvidenceReader {
                IntentEvidenceReadback(
                    packageName = "com.tencent.mm",
                    targetLabel = "文件传输助手",
                    content = secretContent,
                    targetChannel = IntentReadbackChannel.OCR,
                    contentChannel = IntentReadbackChannel.OCR,
                )
            },
            liveIdentity = { currentIdentity },
            liveBounds = { currentBounds },
            intentConfirmer = { _, intent, cid, nonce ->
                assertEquals("文件传输助手", intent.targetLabel)
                currentPkg = "com.android.launcher"
                IntentConfirmationResult(true, ApprovalChannel.OVERLAY, cid, nonce)
            },
            onAuditNote = { notes.add(it) },
        )

        val finalRef = gate.execute(
            "ui_action",
            Level.W,
            JSONObject().put("ref", "e:sess:1:10").put("action", "click"),
        ) { _, ctx ->
            executorCalls++
            ctx.target?.ref
        }

        assertEquals(1, executorCalls)
        assertEquals("e:sess:2:10", finalRef)
        val joinedNotes = notes.joinToString(";")
        assertFalse(joinedNotes.contains(secretContent))
        assertFalse(joinedNotes.contains("intent-fixed-id"))
        assertFalse(joinedNotes.contains("nonce-secret"))
    }

    @Test
    fun `intentTtl expiry rejection and execution failure never resurrect intent or skip reconfirmation`() {
        var now = 1_000L
        val inputStore = InputCommitEvidenceStore(ttlMs = 120_000L, clock = { now })
        val preparedStore = PreparedTargetEvidenceStore(ttlMs = 120_000L, clock = { now })
        inputStore.record(messageText, strict1, readbackVerified = true)
        preparedStore.record("文件传输助手", "com.tencent.mm", strict1, bounds1)

        // 1) 超出 360s intentTtl → E_STALE_REF 且 executor = 0
        var execCalls = 0
        var sleeps = 0
        val ttlGate = createGate(
            now = { now },
            sleep = { ms ->
                sleeps++
                now += ms
                if (sleeps == 1) now += 290_000L
            },
            inputStore = inputStore,
            preparedStore = preparedStore,
            currentForeground = { if (sleeps >= 1) "com.tencent.mm" else "com.android.launcher" },
            contextProvider = {
                SafetyContext(
                    packageName = "com.tencent.mm",
                    activityName = ".ui.LauncherUI",
                    revision = 1L,
                    foregroundKnown = true,
                    target = SafetyTarget(
                        focusIdentity = strict1,
                        focusedInputBounds = bounds1,
                        inputCommitEvidence = inputStore.current(strict1),
                        preparedTargetEvidence = preparedStore.current("com.tencent.mm", strict1, bounds1),
                    ),
                )
            },
            evidenceReader = IntentEvidenceReader {
                // 重建读回耗时推进 75s，使总批准耗时达到 290s + 75s = 365s > 360s intentTtl。
                now += 75_000L
                IntentApprovalFixtures.readback()
            },
            intentConfirmer = { _, _, cid, nonce ->
                IntentConfirmationResult(true, ApprovalChannel.OVERLAY, cid, nonce)
            },
        )
        expectGatewayError(ErrorCode.E_STALE_REF) {
            ttlGate.execute("press_key", Level.W, JSONObject().put("key", "enter")) { _, _ -> execCalls++ }
        }
        assertEquals(0, execCalls)

        // 2) 执行失败不复活意图：下一次调用必须重新弹卡（拒绝时 executor 不增加）。
        now = 1_000L
        inputStore.record(messageText, strict1, readbackVerified = true)
        preparedStore.record("文件传输助手", "com.tencent.mm", strict1, bounds1)
        var cards = 0
        var secondAttemptExecs = 0
        val nonResurrectGate = createGate(
            now = { now },
            sleep = { now += it },
            inputStore = inputStore,
            preparedStore = preparedStore,
            currentForeground = { "com.tencent.mm" },
            contextProvider = {
                SafetyContext(
                    packageName = "com.tencent.mm",
                    activityName = ".ui.LauncherUI",
                    revision = 2L,
                    foregroundKnown = true,
                    target = SafetyTarget(
                        focusIdentity = strict1,
                        focusedInputBounds = bounds1,
                        inputCommitEvidence = inputStore.current(strict1),
                        preparedTargetEvidence = preparedStore.current("com.tencent.mm", strict1, bounds1),
                    ),
                )
            },
            evidenceReader = IntentEvidenceReader { IntentApprovalFixtures.readback() },
            intentConfirmer = { _, _, cid, nonce ->
                cards++
                IntentConfirmationResult(cards == 1, ApprovalChannel.OVERLAY, cid, nonce)
            },
        )
        expectGatewayError(ErrorCode.E_VERIFY_FAIL) {
            nonResurrectGate.execute("press_key", Level.W, JSONObject().put("key", "enter")) { _, _ ->
                throw GatewayError(ErrorCode.E_VERIFY_FAIL, "模拟发送失败")
            }
        }
        expectGatewayError(ErrorCode.E_BLOCKED) {
            nonResurrectGate.execute("press_key", Level.W, JSONObject().put("key", "enter")) { _, _ ->
                secondAttemptExecs++
            }
        }
        assertEquals(2, cards)
        assertEquals(0, secondAttemptExecs)
    }

    @Test
    fun `isRetractableSendLabel respects safety word precedence and traditional folding`() {
        val policy = SafetyPolicy(sensitiveTargets = listOf("保密联系人"))
        assertTrue(policy.isRetractableSendLabel("发送"))
        assertTrue(policy.isRetractableSendLabel("發送"))
        assertFalse(policy.isRetractableSendLabel("删除"))
        assertFalse(policy.isRetractableSendLabel("确认删除"))
        assertFalse(policy.isRetractableSendLabel("确认"))
        assertFalse(policy.isRetractableSendLabel("保密联系人"))
        assertFalse(policy.isRetractableSendLabel(""))
    }

    private fun createGate(
        now: () -> Long,
        sleep: (Long) -> Unit,
        inputStore: InputCommitEvidenceStore,
        preparedStore: PreparedTargetEvidenceStore,
        currentForeground: () -> String?,
        contextProvider: (JSONObject) -> SafetyContext,
        evidenceReader: IntentEvidenceReader,
        intentConfirmer: (SafetyDecision.ConfirmationRequired, ApprovalIntent, String, String) -> IntentConfirmationResult,
        legacyConfirmer: (SafetyDecision.ConfirmationRequired) -> Boolean = { true },
        onExecutionFailure: (Throwable) -> Unit = {},
        onStaleAfterApproval: (String, SafetyContext) -> Unit = { _, _ -> },
        onAuditNote: (String) -> Unit = {},
        foregroundPollIntervalMs: Long = 250L,
        liveIdentity: () -> FocusIdentity = { strict1 },
        liveBounds: () -> String = { bounds1 },
    ): SafetyGate {
        val timing = IntentApprovalTiming()
        return SafetyGate(
            policy = SafetyPolicy(),
            confirmer = legacyConfirmer,
            contextProvider = contextProvider,
            onExecutionFailure = onExecutionFailure,
            onStaleAfterApproval = onStaleAfterApproval,
            semanticIntent = SemanticIntentConfig(
                timing = timing,
                dependenciesForTier = { tier ->
                    if (tier == RiskTier.RETRACTABLE) {
                        IntentApprovalDependencies(RiskTier.RETRACTABLE, timing, evidenceReader)
                    } else {
                        IntentApprovalDependencies(RiskTier.IRREVERSIBLE, timing)
                    }
                },
                clock = now,
                sleep = sleep,
                foregroundPollIntervalMs = foregroundPollIntervalMs,
                intentIdGenerator = { "intent-fixed-id" },
                confirmationIdGenerator = { "c-fixed-1" },
                nonceGenerator = { "nonce-secret" },
                intentConfirmer = intentConfirmer,
                currentForegroundPackage = currentForeground,
                installRebuiltEvidence = { approved, rebuilt ->
                    val currentId = liveIdentity()
                    inputStore.installRebuilt(
                        rebuilt = rebuilt,
                        preview = approved.preview,
                        ocrBaseline = approved.ocrBaseline,
                        identity = currentId,
                        readbackVerified = true,
                    )
                    preparedStore.installRebuilt(
                        rebuilt = rebuilt,
                        identity = currentId,
                        bounds = liveBounds(),
                    )
                    true
                },
                onAuditNote = onAuditNote,
            ),
        )
    }

    private fun expectGatewayError(code: ErrorCode, block: () -> Unit): GatewayError {
        try {
            block()
            fail("预期抛出 $code")
        } catch (error: GatewayError) {
            assertEquals(code, error.code)
            return error
        }
        throw AssertionError("unreachable")
    }
}
