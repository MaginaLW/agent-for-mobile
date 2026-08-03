package dev.magina.gateway.testing

// debug-only test-control contract tests.

import dev.magina.gateway.core.ApprovalChannel
import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.GatewayError
import dev.magina.gateway.core.IntentApprovalClocks
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption

class TestControlTest {
    @get:Rule
    val temp = TemporaryFolder()

    private val now = 1_000_000L
    private val attempt = TestConfirmationAttempt(
        confirmationId = "abc123def456",
        toolName = "press_key",
        action = "enter",
        initialPackage = "com.tencent.mm",
        inputLength = 19,
        inputSha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    )

    @Test
    fun `absent control is a production-safe no-op and does not capture`() {
        val control = debugControl()
        var captures = 0

        val session = control.onConfirmationShown(attempt) {
            captures++
            TestConfirmationCapture(byteArrayOf(1), cardVisible = true, attempts = 1)
        }

        assertFalse(session.armed)
        assertEquals(0, captures)
    }

    @Test
    fun `matching allow command captures once but never performs home`() {
        writeControl(leg = "allow", nonce = "nonce-allow-0001")
        val control = debugControl()
        var homeCalls = 0

        val session = control.onConfirmationShown(attempt) { TestConfirmationCapture(byteArrayOf(1, 2, 3), cardVisible = true, attempts = 1) }
        control.onConfirmationDecision(session, TestConfirmationDecision.ALLOWED, ApprovalChannel.OVERLAY)
        control.afterAllowed(session, attempt, performHome = { homeCalls++; true }) {
            TestForeground(known = true, packageName = "launcher")
        }

        assertTrue(session.armed)
        assertEquals(attempt.confirmationId, session.confirmId)
        assertEquals(0, homeCalls)
        assertFalse(File(temp.root, DebugTestControl.CONTROL_FILE_NAME).exists())
        assertStateContains("allowed", session.confirmId)
        val state = File(temp.root, DebugTestControl.STATE_FILE_NAME).readText()
        assertTrue(state.contains("\"input_length\":19"))
        assertTrue(state.contains("\"input_sha256\":\"${attempt.inputSha256}\""))
        assertFalse(state.contains("input_preview"))
        assertFalse(state.contains("P0ALLOW"))
    }

    /**
     * 批次 2 判据 1 靠它才是机械证据：状态文件必须说出决定来自哪条 surface，
     * 而**没人点**的那种情况一个字都不许写——凭空写个 overlay 等于伪造"人在卡上点过"。
     */
    @Test
    fun `decision channel is written only when someone actually decided`() {
        writeControl(leg = "allow", nonce = "nonce-channel-0001")
        val control = debugControl()

        val session = control.onConfirmationShown(attempt) {
            TestConfirmationCapture(byteArrayOf(1), cardVisible = true, attempts = 1)
        }
        control.onConfirmationDecision(session, TestConfirmationDecision.ALLOWED, ApprovalChannel.NOTIFICATION)

        assertTrue(File(temp.root, DebugTestControl.STATE_FILE_NAME).readText()
            .contains("\"decided_via\":\"notification\""))
    }

    @Test
    fun `timed out confirmation writes no decision channel at all`() {
        writeControl(leg = "allow", nonce = "nonce-channel-0002")
        val control = debugControl()

        val session = control.onConfirmationShown(attempt) {
            TestConfirmationCapture(byteArrayOf(1), cardVisible = true, attempts = 1)
        }
        control.onConfirmationDecision(session, TestConfirmationDecision.TIMED_OUT, null)

        val state = File(temp.root, DebugTestControl.STATE_FILE_NAME).readText()
        assertTrue(state.contains("\"state\":\"timed_out\""))
        assertFalse(state.contains("decided_via"))
    }

    /**
     * Deny 腿必须能走到「弹卡 + 存证」这一步——**这正是它要测的东西**：卡出来了、真人点了拒绝。
     * 白名单漏了 deny 的表现极具迷惑性：press_key 回 E_BLOCKED，而 E_BLOCKED 恰好是本腿的
     * 预期错误码，执行器会照常报告"符合预期"，只有 runner 独立读 confirmation 字段才拦得住
     * （2026-07-31 真机实锤，31 秒就结束、卡根本没弹）。
     */
    @Test
    fun `deny command captures the card and never performs home`() {
        writeControl(leg = "deny", nonce = "nonce-deny-0001")
        val control = debugControl()
        var homeCalls = 0

        val session = control.onConfirmationShown(attempt) { TestConfirmationCapture(byteArrayOf(4, 5), cardVisible = true, attempts = 1) }
        control.onConfirmationDecision(session, TestConfirmationDecision.DENIED, ApprovalChannel.OVERLAY)

        assertTrue(session.armed)
        assertEquals(attempt.confirmationId, session.confirmId)
        assertEquals(0, homeCalls)
        assertStateContains("denied", session.confirmId)
        assertTrue(File(temp.root, "confirmation-${attempt.confirmationId}.png").isFile)
        // 拒绝之后不存在"允许后动作"，afterAllowed 走到就是错的。
        expectError(ErrorCode.E_BLOCKED) {
            control.afterAllowed(session, attempt, performHome = { homeCalls++; true }) {
                TestForeground(known = true, packageName = "launcher")
            }
        }
        assertEquals(0, homeCalls)
    }

    @Test
    fun `state and evidence use the exact confirmation id already shown on card`() {
        writeControl(leg = "allow", nonce = "nonce-card-id-0001")
        val session = debugControl().onConfirmationShown(attempt) { TestConfirmationCapture(byteArrayOf(1), cardVisible = true, attempts = 1) }

        assertEquals(attempt.confirmationId, session.confirmId)
        val state = File(temp.root, DebugTestControl.STATE_FILE_NAME).readText()
        assertTrue(state.contains("\"confirm_id\":\"${attempt.confirmationId}\""))
        assertTrue(File(temp.root, "confirmation-${attempt.confirmationId}.png").isFile)
    }

    @Test
    fun `after allowed rejects a different confirmation id`() {
        writeControl(leg = "allow", nonce = "nonce-id-swap-0001")
        val control = debugControl()
        val session = control.onConfirmationShown(attempt) { TestConfirmationCapture(byteArrayOf(1), cardVisible = true, attempts = 1) }
        control.onConfirmationDecision(session, TestConfirmationDecision.ALLOWED, ApprovalChannel.OVERLAY)
        val swapped = attempt.copy(confirmationId = "000000000000")

        expectError(ErrorCode.E_BLOCKED) {
            control.afterAllowed(session, swapped, { true }) {
                TestForeground(known = true, packageName = "launcher")
            }
        }
    }

    @Test
    fun `stale command performs home once and waits for known non WeChat`() {
        writeControl(leg = "stale", nonce = "nonce-stale-0001")
        var foregroundReads = 0
        var homeCalls = 0
        val control = debugControl(sleep = {})
        val session = control.onConfirmationShown(attempt) { TestConfirmationCapture(byteArrayOf(7), cardVisible = true, attempts = 1) }
        control.onConfirmationDecision(session, TestConfirmationDecision.ALLOWED, ApprovalChannel.OVERLAY)

        control.afterAllowed(session, attempt, performHome = { homeCalls++; true }) {
            foregroundReads++
            when (foregroundReads) {
                1 -> TestForeground(known = false, packageName = "")
                2 -> TestForeground(known = true, packageName = "com.tencent.mm")
                else -> TestForeground(known = true, packageName = "com.android.launcher")
            }
        }
        expectError(ErrorCode.E_BLOCKED) {
            control.afterAllowed(session, attempt, performHome = { homeCalls++; true }) {
                TestForeground(known = true, packageName = "com.android.launcher")
            }
        }

        assertEquals(1, homeCalls)
        assertEquals(3, foregroundReads)
    }

    /**
     * 2026-08-02 真机上这条等待超时过一次（1a 那腿：人从通知点了允许，网关侧仍认为前台是微信）。
     * 当时的消息只说"没等到"——**读了几次、每次读到什么、等了多久全都不知道**，只能靠猜，
     * 下一轮又得烧用户一次往返。这条用例钉住"它自己会说"，**只加可观测性，判据与超时值不动**。
     */
    @Test
    fun `foreground wait timeout reports what it actually saw`() {
        var monotonic = 0L
        writeControl(leg = "stale", nonce = "nonce-wait-0001")
        val control = debugControl(monotonicClock = { monotonic }, sleep = { monotonic += it })
        val session = control.onConfirmationShown(attempt) {
            TestConfirmationCapture(byteArrayOf(7), cardVisible = true, attempts = 1)
        }
        control.onConfirmationDecision(session, TestConfirmationDecision.ALLOWED, ApprovalChannel.NOTIFICATION)

        val error = expectError(ErrorCode.E_CHANNEL_DOWN) {
            // 真机上看到的就是这个：前台身份是**已知的**，但仍旧是微信——切 App 没做完。
            control.afterAllowed(session, attempt, performHome = { true }) {
                TestForeground(known = true, packageName = "com.tencent.mm", reason = "none")
            }
        }

        val message = error.message.orEmpty()
        assertTrue("缺读取次数：$message", message.contains("reads="))
        assertTrue("缺等待时长：$message", message.contains("waited_ms="))
        // 关键的一条：必须说出它一直看到的是谁，否则"没等到"依旧是句废话。
        assertTrue("没说出看到的包名：$message", message.contains("com.tencent.mm"))
        assertTrue("没说出身份是否已知：$message", message.contains("/known"))
    }

    @Test
    fun `foreground wait trace merges identical reads instead of listing every frame`() {
        val trace = DebugTestControl.ForegroundWaitTrace()
        repeat(3) { trace.add(TestForeground(known = true, packageName = "com.tencent.mm", reason = "none")) }
        trace.add(TestForeground(known = false, packageName = "", reason = "no_application_window"))

        val described = trace.describe(1234)

        assertEquals(
            "reads=4 waited_ms=1234 observed=[com.tencent.mm/known:none×3, -/unknown:no_application_window×1]",
            described,
        )
    }

    @Test
    fun `home requires exactly one observed allowed decision`() {
        val decisions = listOf<TestConfirmationDecision?>(
            null,
            TestConfirmationDecision.DENIED,
            TestConfirmationDecision.TIMED_OUT,
        )
        decisions.forEachIndexed { index, decision ->
            writeControl(leg = "stale", nonce = "nonce-decision-000$index")
            val control = debugControl()
            val session = control.onConfirmationShown(attempt) { TestConfirmationCapture(byteArrayOf(1), cardVisible = true, attempts = 1) }
            decision?.let { control.onConfirmationDecision(session, it, ApprovalChannel.OVERLAY) }
            var homeCalls = 0

            expectError(ErrorCode.E_BLOCKED) {
                control.afterAllowed(session, attempt, { homeCalls++; true }) {
                    TestForeground(true, "launcher")
                }
            }
            assertEquals(0, homeCalls)
        }
    }

    @Test
    fun `repeated or conflicting decision invalidates session before home`() {
        writeControl(leg = "stale", nonce = "nonce-repeat-0001")
        val control = debugControl()
        val session = control.onConfirmationShown(attempt) { TestConfirmationCapture(byteArrayOf(1), cardVisible = true, attempts = 1) }
        control.onConfirmationDecision(session, TestConfirmationDecision.ALLOWED, ApprovalChannel.OVERLAY)
        expectError(ErrorCode.E_BLOCKED) {
            control.onConfirmationDecision(session, TestConfirmationDecision.ALLOWED, ApprovalChannel.OVERLAY)
        }
        var homeCalls = 0

        expectError(ErrorCode.E_BLOCKED) {
            control.afterAllowed(session, attempt, { homeCalls++; true }) {
                TestForeground(true, "launcher")
            }
        }
        assertEquals(0, homeCalls)
    }

    @Test
    fun `expired mismatched and unsupported commands fail closed without capture`() {
        val cases = listOf(
            commandJson(expiresAtMs = now - 1),
            commandJson(runId = ""),
            // 曾经写的是 leg="deny"，把「deny 不被支持」当成了预期行为——
            // 2026-07-31 Deny 腿接进 runner 后，这条用例就变成了在**保护一个 bug**：
            // 真机上确认卡根本不弹，press_key 直接回 E_BLOCKED("测试腿不在白名单")。
            // 换成一个真正不支持的腿名，白名单本身仍然 fail-closed。
            commandJson(leg = "purchase"),
            commandJson(tool = "ui_action"),
            commandJson(initialPackage = "com.example.other"),
            commandJson(extra = "\"decision\":\"allowed\",")
        )
        cases.forEachIndexed { index, json ->
            File(temp.root, DebugTestControl.CONTROL_FILE_NAME).writeText(json)
            var captures = 0
            expectError(ErrorCode.E_BLOCKED) {
                debugControl().onConfirmationShown(attempt) { captures++; TestConfirmationCapture(byteArrayOf(1), cardVisible = true, attempts = 1) }
            }
            assertEquals("case $index", 0, captures)
        }
    }

    @Test
    fun `control JSON rejects type coercion and unknown fields`() {
        val valid = commandJson(nonce = "nonce-types-0001")
        val cases = listOf(
            valid.replace("\"run_id\":\"run-20260722-0001\"", "\"run_id\":123"),
            valid.replace("\"leg\":\"stale\"", "\"leg\":7"),
            valid.replace("\"nonce\":\"nonce-types-0001\"", "\"nonce\":8"),
            valid.replace("\"tool\":\"press_key\"", "\"tool\":9"),
            valid.replace("\"action\":\"enter\"", "\"action\":10"),
            valid.replace("\"initial_package\":\"com.tencent.mm\"", "\"initial_package\":11"),
            valid.replace("\"expires_at_ms\":1060000", "\"expires_at_ms\":\"1060000\""),
            valid.replace("\"expires_at_ms\":1060000", "\"expires_at_ms\":1060000.5"),
            valid.replace("\"stale_after_allow\":true", "\"stale_after_allow\":\"true\""),
            valid.replace("\"stale_after_allow\":true", "\"stale_after_allow\":false"),
            valid.replace("{", "{\"unknown\":true,", ignoreCase = false),
        )
        cases.forEachIndexed { index, json ->
            File(temp.root, DebugTestControl.CONTROL_FILE_NAME).writeText(json)
            expectError(ErrorCode.E_BLOCKED) {
                debugControl().onConfirmationShown(attempt) { TestConfirmationCapture(byteArrayOf(1), cardVisible = true, attempts = 1) }
            }
            assertFalse("case $index must consume invalid file", File(temp.root, DebugTestControl.CONTROL_FILE_NAME).exists())
        }
    }

    @Test
    fun `nonce is single use even if command file is recreated`() {
        writeControl(leg = "stale", nonce = "nonce-replay-0001")
        val control = debugControl()
        control.onConfirmationShown(attempt) { TestConfirmationCapture(byteArrayOf(1), cardVisible = true, attempts = 1) }
        writeControl(leg = "stale", nonce = "nonce-replay-0001")

        expectError(ErrorCode.E_BLOCKED) {
            control.onConfirmationShown(attempt) { TestConfirmationCapture(byteArrayOf(2), cardVisible = true, attempts = 1) }
        }
    }

    @Test
    fun `nonce ledger never forgets the first nonce after more than 64 consumptions`() {
        val control = debugControl()
        repeat(65) { index ->
            val nonce = "nonce-ledger-${index.toString().padStart(4, '0')}"
            writeControl(leg = "allow", nonce = nonce)
            control.onConfirmationShown(attempt) { TestConfirmationCapture(byteArrayOf(1), cardVisible = true, attempts = 1) }
        }
        writeControl(leg = "allow", nonce = "nonce-ledger-0000")

        expectError(ErrorCode.E_BLOCKED) {
            control.onConfirmationShown(attempt) { TestConfirmationCapture(byteArrayOf(2), cardVisible = true, attempts = 1) }
        }
    }

    @Test
    fun `claimed command is isolated from a replacement written at original path`() {
        var replaceOnce = true
        val control = debugControl(
            afterControlClaimed = {
                if (replaceOnce) {
                    replaceOnce = false
                    File(temp.root, DebugTestControl.CONTROL_FILE_NAME).writeText(
                        commandJson(leg = "allow", nonce = "nonce-claim-new-01"),
                    )
                }
            },
        )
        writeControl(leg = "allow", nonce = "nonce-claim-old-01")

        control.onConfirmationShown(attempt) { TestConfirmationCapture(byteArrayOf(1), cardVisible = true, attempts = 1) }
        assertTrue(File(temp.root, DebugTestControl.CONTROL_FILE_NAME).isFile)
        control.onConfirmationShown(attempt) { TestConfirmationCapture(byteArrayOf(2), cardVisible = true, attempts = 1) }

        assertFalse(File(temp.root, DebugTestControl.CONTROL_FILE_NAME).exists())
    }

    @Test
    fun `nonce is persisted before claimed command is deleted`() {
        val events = mutableListOf<String>()
        val writer = AtomicPrivateFileWriter(
            tempIdFactory = { "ordered" },
            mover = { source, target ->
                if (target.name == "test-control-consumed-nonces") events += "nonce-persisted"
                Files.move(
                    source.toPath(), target.toPath(),
                    StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE,
                )
            },
        )
        writeControl(leg = "allow", nonce = "nonce-order-0001")
        val control = debugControl(
            atomicWriter = writer,
            claimedDeleter = { claimed ->
                events += "claimed-deleted"
                assertTrue(File(temp.root, "test-control-consumed-nonces").isFile)
                Files.deleteIfExists(claimed.toPath())
            },
        )

        control.onConfirmationShown(attempt) { TestConfirmationCapture(byteArrayOf(1), cardVisible = true, attempts = 1) }

        assertTrue(events.indexOf("nonce-persisted") < events.indexOf("claimed-deleted"))
    }

    @Test
    fun `claimed deletion failure remains fail closed but nonce stays consumed`() {
        writeControl(leg = "allow", nonce = "nonce-delete-fail-01")
        var captures = 0
        val control = debugControl(claimedDeleter = { false })

        expectError(ErrorCode.E_BLOCKED) {
            control.onConfirmationShown(attempt) { captures++; TestConfirmationCapture(byteArrayOf(1), cardVisible = true, attempts = 1) }
        }

        assertEquals(0, captures)
        assertTrue(File(temp.root, "test-control-consumed-nonces").readLines().contains("nonce-delete-fail-01"))
        assertTrue(claimedFiles().isNotEmpty())

        writeControl(leg = "allow", nonce = "nonce-delete-fail-01")
        expectError(ErrorCode.E_BLOCKED) {
            debugControl().onConfirmationShown(attempt) { captures++; TestConfirmationCapture(byteArrayOf(2), cardVisible = true, attempts = 1) }
        }
        assertEquals(0, captures)
    }

    @Test
    fun `nonce persistence failure retains claimed command and never creates session`() {
        val writer = AtomicPrivateFileWriter(
            tempIdFactory = { "nonce-write-fail" },
            textWriter = { file, text ->
                file.writeText(text)
                throw IllegalStateException("persist failed")
            },
        )
        writeControl(leg = "allow", nonce = "nonce-persist-fail")
        var captures = 0

        expectError(ErrorCode.E_BLOCKED) {
            debugControl(atomicWriter = writer).onConfirmationShown(attempt) {
                captures++
                TestConfirmationCapture(byteArrayOf(1), cardVisible = true, attempts = 1)
            }
        }

        assertEquals(0, captures)
        assertFalse(File(temp.root, "test-control-consumed-nonces").exists())
        assertTrue(claimedFiles().isNotEmpty())
    }

    @Test
    fun `command expiring while human confirms never performs home`() {
        var currentTime = now
        File(temp.root, DebugTestControl.CONTROL_FILE_NAME).writeText(
            commandJson(nonce = "nonce-expire-0001", expiresAtMs = now + 10),
        )
        val control = debugControl(clock = { currentTime })
        val session = control.onConfirmationShown(attempt) { TestConfirmationCapture(byteArrayOf(1), cardVisible = true, attempts = 1) }
        control.onConfirmationDecision(session, TestConfirmationDecision.ALLOWED, ApprovalChannel.OVERLAY)
        currentTime = now + 11
        var homeCalls = 0

        expectError(ErrorCode.E_BLOCKED) {
            control.afterAllowed(session, attempt, { homeCalls++; true }) {
                TestForeground(true, "launcher")
            }
        }

        assertEquals(0, homeCalls)
    }

    @Test
    fun `foreground timeout uses monotonic deadline and performs home only once`() {
        var monotonic = 0L
        var homeCalls = 0
        writeControl(leg = "stale", nonce = "nonce-timeout-0001")
        val control = debugControl(
            monotonicClock = { monotonic },
            sleep = { monotonic += it },
        )
        val session = control.onConfirmationShown(attempt) { TestConfirmationCapture(byteArrayOf(1), cardVisible = true, attempts = 1) }
        control.onConfirmationDecision(session, TestConfirmationDecision.ALLOWED, ApprovalChannel.OVERLAY)

        expectError(ErrorCode.E_CHANNEL_DOWN) {
            control.afterAllowed(session, attempt, { homeCalls++; true }) {
                TestForeground(known = true, packageName = "com.tencent.mm")
            }
        }

        assertEquals(1, homeCalls)
        assertTrue(monotonic >= 1_000)
    }

    @Test
    fun `evidence failure fails supervised leg before a decision can be made`() {
        writeControl(leg = "allow", nonce = "nonce-evidence-001")

        expectError(ErrorCode.E_CHANNEL_DOWN) {
            debugControl().onConfirmationShown(attempt) { throw IllegalStateException("capture failed") }
        }

        assertStateContains("error", null)
    }

    @Test
    fun `release control is inert and exposes no decision mutation surface`() {
        val methods = TestControl::class.java.methods.map { it.name }.toSet()
        assertFalse(methods.any { it.contains("allow", ignoreCase = true) && it.startsWith("set") })
        assertFalse(methods.any { it.contains("deny", ignoreCase = true) && it.startsWith("set") })

        var captured = false
        var home = false
        val release = NoopTestControl()
        val session = release.onConfirmationShown(attempt) { captured = true; TestConfirmationCapture(byteArrayOf(1), cardVisible = true, attempts = 1) }
        release.onConfirmationDecision(session, TestConfirmationDecision.ALLOWED, ApprovalChannel.OVERLAY)
        release.afterAllowed(session, attempt, { home = true; true }) {
            TestForeground(true, "launcher")
        }

        assertFalse(session.armed)
        assertFalse(captured)
        assertFalse(home)
    }

    // —— 等前台预算的按腿缩短（spec §9.4）：只许缩短，不许延长 ——

    @Test
    fun `stale leg shortens the foreground wait so nobody stands there for five minutes`() {
        writeControl(leg = "stale", nonce = "nonce-stale-clock1")
        val control = debugControl()
        val session = control.onConfirmationShown(attempt) {
            TestConfirmationCapture(byteArrayOf(1), cardVisible = true, attempts = 1)
        }

        val clocks = control.intentClocks(session, IntentApprovalClocks())

        assertEquals(DebugTestControl.STALE_LEG_FOREGROUND_WAIT_MS, clocks.foregroundWaitBudgetMs)
        // 缩短的只是等前台那一项：决定期与意图有效期是用户拍板的数，测试脚手架不许碰。
        assertEquals(IntentApprovalClocks().decisionTimeoutMs, clocks.decisionTimeoutMs)
        assertEquals(IntentApprovalClocks().intentTtlMs, clocks.intentTtlMs)
    }

    @Test
    fun `allow leg keeps the production budget the user decided on`() {
        writeControl(leg = "allow", nonce = "nonce-allow-clock1")
        val control = debugControl()
        val session = control.onConfirmationShown(attempt) {
            TestConfirmationCapture(byteArrayOf(1), cardVisible = true, attempts = 1)
        }

        assertEquals(
            IntentApprovalClocks().foregroundWaitBudgetMs,
            control.intentClocks(session, IntentApprovalClocks()).foregroundWaitBudgetMs,
        )
    }

    @Test
    fun `an unarmed session never touches the clocks`() {
        val defaults = IntentApprovalClocks()

        assertEquals(defaults, debugControl().intentClocks(InactiveTestControlSession, defaults))
    }

    @Test
    fun `the shortening path cannot be turned into a lengthening one`() {
        // 这条不对称是判据本身：延长会让用户拍板的"5 分钟"被测试脚手架悄悄改宽，
        // 而现场看到的会是一条**通过**的腿。
        val tight = IntentApprovalClocks(foregroundWaitBudgetMs = 5_000)
        writeControl(leg = "stale", nonce = "nonce-stale-clock2")
        val control = debugControl()
        val session = control.onConfirmationShown(attempt) {
            TestConfirmationCapture(byteArrayOf(1), cardVisible = true, attempts = 1)
        }

        assertEquals(5_000L, control.intentClocks(session, tight).foregroundWaitBudgetMs)
        assertTrue(
            runCatching { tight.withShorterForegroundWait(600_000) }.exceptionOrNull()
                is IllegalArgumentException,
        )
    }

    private fun debugControl(
        sleep: (Long) -> Unit = {},
        clock: () -> Long = { now },
        monotonicClock: () -> Long = clock,
        afterControlClaimed: (File) -> Unit = {},
        claimedDeleter: (File) -> Boolean = { Files.deleteIfExists(it.toPath()) },
        atomicWriter: AtomicPrivateFileWriter = AtomicPrivateFileWriter(),
    ): DebugTestControl = DebugTestControl(
        filesDir = temp.root,
        cacheDir = temp.root,
        clock = clock,
        monotonicClock = monotonicClock,
        sleep = sleep,
        afterControlClaimed = afterControlClaimed,
        claimedDeleter = claimedDeleter,
        atomicWriter = atomicWriter,
        foregroundTimeoutMs = 1_000,
    )

    private fun claimedFiles(): List<File> = temp.root.listFiles()
        ?.filter { it.name.startsWith(".test-control.claimed-") }
        .orEmpty()

    private fun writeControl(
        runId: String = "run-20260722-0001",
        leg: String,
        nonce: String,
    ) {
        File(temp.root, DebugTestControl.CONTROL_FILE_NAME).writeText(
            commandJson(runId = runId, leg = leg, nonce = nonce),
        )
    }

    private fun commandJson(
        runId: String = "run-20260722-0001",
        leg: String = "stale",
        nonce: String = "nonce-default-0001",
        expiresAtMs: Long = now + 60_000,
        tool: String = "press_key",
        initialPackage: String = "com.tencent.mm",
        extra: String = "",
    ): String = """{
        $extra
        "run_id":"$runId",
        "leg":"$leg",
        "nonce":"$nonce",
        "expires_at_ms":$expiresAtMs,
        "tool":"$tool",
        "action":"enter",
        "initial_package":"$initialPackage",
        "stale_after_allow":${leg == "stale"}
    }""".trimIndent()

    private fun assertStateContains(state: String, confirmId: String?) {
        val text = File(temp.root, DebugTestControl.STATE_FILE_NAME).readText()
        assertTrue(text.contains("\"state\":\"$state\""))
        confirmId?.let { assertTrue(text.contains("\"confirm_id\":\"$it\"")) }
        assertFalse(text.contains("P0 安全硬门测试"))
    }

    private fun expectError(code: ErrorCode, block: () -> Unit): GatewayError {
        try {
            block()
            fail("expected $code")
        } catch (error: GatewayError) {
            assertEquals(code, error.code)
            return error
        }
        throw AssertionError("unreachable")
    }
}
