package dev.magina.gateway.testing

import android.content.Context
import android.os.SystemClock
import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.GatewayError
import org.json.JSONObject
import java.io.File
import java.math.BigDecimal
import java.time.Instant
import java.util.UUID
import java.nio.file.Files
import java.nio.file.StandardCopyOption

class DebugTestControl(
    private val filesDir: File,
    private val cacheDir: File,
    private val clock: () -> Long = { System.currentTimeMillis() },
    private val monotonicClock: () -> Long = { SystemClock.elapsedRealtime() },
    private val sleep: (Long) -> Unit = { Thread.sleep(it) },
    private val claimIdFactory: () -> String = { UUID.randomUUID().toString() },
    private val afterControlClaimed: (File) -> Unit = {},
    private val claimedDeleter: (File) -> Boolean = { Files.deleteIfExists(it.toPath()) },
    private val foregroundTimeoutMs: Long = 5_000,
    private val atomicWriter: AtomicPrivateFileWriter = AtomicPrivateFileWriter(),
) : TestControl {

    companion object {
        const val CONTROL_FILE_NAME = "test-control.json"
        const val STATE_FILE_NAME = "test-confirmation-state.json"
        private const val NONCE_FILE_NAME = "test-control-consumed-nonces"
        private const val MAX_FUTURE_MS = 5 * 60_000L
        private const val WECHAT_PACKAGE = "com.tencent.mm"
        private val TOKEN_PATTERN = Regex("[A-Za-z0-9._-]{8,128}")
    }

    private data class Command(
        val runId: String,
        val leg: String,
        val nonce: String,
        val expiresAtMs: Long,
        val tool: String,
        val action: String,
        val initialPackage: String,
        val staleAfterAllow: Boolean,
    )

    private enum class DecisionState {
        AWAITING,
        ALLOWED,
        DENIED,
        TIMED_OUT,
        INVALID,
        CONSUMED,
    }

    private data class Session(
        val command: Command,
        val attempt: TestConfirmationAttempt,
        override val confirmId: String,
        var decisionState: DecisionState = DecisionState.AWAITING,
        var cardVisible: Boolean? = null,
        var captureAttempts: Int? = null,
    ) : TestControlSession {
        override val armed: Boolean = true
    }

    @Synchronized
    override fun onConfirmationShown(
        attempt: TestConfirmationAttempt,
        capture: () -> TestConfirmationCapture,
    ): TestControlSession {
        val controlFile = File(filesDir, CONTROL_FILE_NAME)
        if (!controlFile.isFile) return InactiveTestControlSession

        val claimedFile = claimControlFile(controlFile)
        val command = try {
            afterControlClaimed(claimedFile)
            parseAndValidate(claimedFile.readText(), attempt).also {
                if (attempt.inputLength == null || attempt.inputLength < 0 ||
                    attempt.inputSha256?.matches(Regex("^[0-9a-f]{64}$")) != true
                ) throw blocked("debug 确认输入摘要缺失或无效")
            }
        } catch (error: Throwable) {
            runCatching { claimedDeleter(claimedFile) }
            if (error is GatewayError) throw error
            throw blocked("debug 测试控制文件无效：${error.javaClass.simpleName}")
        }
        // crash-safe 顺序：先持久化消费，再删除 claimed；任一步失败都不得建立 session。
        try {
            consumeNonce(command.nonce)
        } catch (error: Throwable) {
            if (error is GatewayError) throw error
            throw blocked("debug 测试 nonce 无法持久化消费状态")
        }
        val deleted = try {
            claimedDeleter(claimedFile)
        } catch (_: Throwable) {
            false
        }
        if (!deleted) throw blocked("debug 已消费控制文件无法删除")

        if (!attempt.confirmationId.matches(Regex("^[a-f0-9]{12}$"))) {
            throw blocked("debug 确认编号格式无效")
        }
        val session = Session(command, attempt, attempt.confirmationId)
        writeState(session, "awaiting")
        val evidenceFile = "confirmation-${session.confirmId}.png"
        try {
            val shot = capture()
            if (shot.png.isEmpty()) throw IllegalStateException("empty png")
            atomicWriter.writeBytes(File(cacheDir, evidenceFile), shot.png)
            // 卡不在图里也照样落盘并进入 awaiting——但状态文件必须如实写明，
            // 让 PC 侧看得见"这张证据其实没拍到卡"，而不是默默当成有效证据。
            session.cardVisible = shot.cardVisible
            session.captureAttempts = shot.attempts
            writeState(session, "evidence_ready", evidenceFile)
        } catch (error: Throwable) {
            writeState(session, "error", errorCode = error.javaClass.simpleName)
            throw GatewayError(
                ErrorCode.E_CHANNEL_DOWN,
                "监督式确认取证失败：${error.javaClass.simpleName}",
                channel = "test-evidence",
                retryable = false,
                fallback = "本测试腿失败并停止；普通非监督确认路径不受影响",
            ).apply { initCause(error) }
        }
        return session
    }

    @Synchronized
    override fun onConfirmationDecision(
        session: TestControlSession,
        decision: TestConfirmationDecision,
    ) {
        val debug = session as? Session ?: return
        if (debug.decisionState != DecisionState.AWAITING) {
            debug.decisionState = DecisionState.INVALID
            writeState(debug, "error", errorCode = "repeated_decision")
            throw blocked("debug 确认会话收到重复或冲突决定")
        }
        val state = when (decision) {
            TestConfirmationDecision.ALLOWED -> {
                debug.decisionState = DecisionState.ALLOWED
                "allowed"
            }
            TestConfirmationDecision.DENIED -> {
                debug.decisionState = DecisionState.DENIED
                "denied"
            }
            TestConfirmationDecision.TIMED_OUT -> {
                debug.decisionState = DecisionState.TIMED_OUT
                "timed_out"
            }
        }
        writeState(debug, state, evidenceFile = "confirmation-${debug.confirmId}.png")
    }

    @Synchronized
    override fun afterAllowed(
        session: TestControlSession,
        attempt: TestConfirmationAttempt,
        performHome: () -> Boolean,
        foreground: () -> TestForeground,
    ) {
        val debug = session as? Session ?: return
        if (debug.decisionState != DecisionState.ALLOWED) {
            throw blocked("debug 确认会话没有唯一且有效的真人允许决定")
        }
        if (debug.attempt != attempt || debug.confirmId != attempt.confirmationId) {
            throw blocked("debug 确认会话与卡片确认编号不匹配")
        }
        debug.decisionState = DecisionState.CONSUMED
        if (debug.command.expiresAtMs <= clock()) throw blocked("debug 测试指令在真人确认前已过期")
        if (!matches(debug.command, attempt)) throw blocked("确认后的动作上下文不再匹配测试指令")
        if (!debug.command.staleAfterAllow) return
        if (!performHome()) throw GatewayError(
            ErrorCode.E_CHANNEL_DOWN,
            "监督式上下文切换失败",
            channel = "test-control",
            retryable = false,
        )

        val started = monotonicClock()
        val deadline = if (Long.MAX_VALUE - started < foregroundTimeoutMs) Long.MAX_VALUE
        else started + foregroundTimeoutMs
        while (true) {
            val current = foreground()
            if (current.known && current.packageName.isNotBlank() && current.packageName != WECHAT_PACKAGE) return
            val remaining = deadline - monotonicClock()
            if (remaining <= 0) break
            sleep(minOf(50, remaining))
        }
        throw GatewayError(
            ErrorCode.E_CHANNEL_DOWN,
            "监督式上下文切换后前台未成为已知非目标 App",
            channel = "test-control",
            retryable = false,
        )
    }

    private fun claimControlFile(source: File): File {
        val claimed = File(filesDir, ".test-control.claimed-${claimIdFactory()}.json")
        if (claimed.exists()) throw blocked("debug 控制文件领取目标已存在")
        try {
            Files.move(source.toPath(), claimed.toPath(), StandardCopyOption.ATOMIC_MOVE)
        } catch (error: Throwable) {
            throw blocked("debug 控制文件无法原子领取：${error.javaClass.simpleName}")
        }
        return claimed
    }

    private fun parseAndValidate(raw: String, attempt: TestConfirmationAttempt): Command {
        val json = JSONObject(raw)
        val allowedKeys = setOf(
            "run_id", "leg", "nonce", "expires_at_ms", "tool", "action", "initial_package", "stale_after_allow",
        )
        val actualKeys = json.keys().asSequence().toSet()
        if (actualKeys != allowedKeys) throw blocked("debug 测试控制字段集合不匹配")

        val command = Command(
            runId = requiredString(json, "run_id"),
            leg = requiredString(json, "leg"),
            nonce = requiredString(json, "nonce"),
            expiresAtMs = requiredInteger(json, "expires_at_ms"),
            tool = requiredString(json, "tool"),
            action = requiredString(json, "action"),
            initialPackage = requiredString(json, "initial_package"),
            staleAfterAllow = requiredBoolean(json, "stale_after_allow"),
        )
        if (!TOKEN_PATTERN.matches(command.runId) || !TOKEN_PATTERN.matches(command.nonce)) {
            throw blocked("debug run id 或 nonce 格式无效")
        }
        // deny 是 2026-07-31 才接进 runner 的第三条腿，这里漏放开，真机上表现为
        // press_key 直接回 E_BLOCKED("debug 测试腿不在白名单")、**确认卡根本不弹**。
        // 执行器按任务卡看到 E_BLOCKED 会认为这一腿符合预期——拦住误判的是 runner 独立读
        // 私有文件里的 confirmation 字段（没有真人决定即判失败）。这正好实锤了
        // 「Deny 腿不能只信 E_BLOCKED」不是理论顾虑：同一个错误码可以来自完全无关的原因。
        if (command.leg !in setOf("allow", "stale", "deny")) throw blocked("debug 测试腿不在白名单")
        if (command.staleAfterAllow != (command.leg == "stale")) {
            throw blocked("debug stale_after_allow 与测试腿不匹配")
        }
        val current = clock()
        if (command.expiresAtMs <= current || command.expiresAtMs > current + MAX_FUTURE_MS) {
            throw blocked("debug 测试指令已过期或有效期过长")
        }
        if (!matches(command, attempt)) throw blocked("debug 测试指令与危险动作不匹配")
        if (consumedNonces().contains(command.nonce)) throw blocked("debug 测试 nonce 已消费")
        return command
    }

    private fun requiredString(json: JSONObject, key: String): String {
        val value = json.opt(key)
        if (value !is String) throw blocked("debug 字段 $key 必须是 JSON string")
        return value
    }

    private fun requiredBoolean(json: JSONObject, key: String): Boolean {
        val value = json.opt(key)
        if (value !is Boolean) throw blocked("debug 字段 $key 必须是 JSON boolean")
        return value
    }

    private fun requiredInteger(json: JSONObject, key: String): Long {
        val value = json.opt(key)
        if (value !is Number) throw blocked("debug 字段 $key 必须是 JSON number")
        return try {
            BigDecimal(value.toString()).longValueExact()
        } catch (_: ArithmeticException) {
            throw blocked("debug 字段 $key 必须是 Long 范围内整数")
        } catch (_: NumberFormatException) {
            throw blocked("debug 字段 $key 必须是 Long 范围内整数")
        }
    }

    private fun matches(command: Command, attempt: TestConfirmationAttempt): Boolean =
        command.tool == "press_key" && command.action == "enter" &&
            command.initialPackage == WECHAT_PACKAGE &&
            command.tool == attempt.toolName && command.action == attempt.action &&
            command.initialPackage == attempt.initialPackage

    private fun consumedNonces(): Set<String> {
        val file = File(filesDir, NONCE_FILE_NAME)
        return if (file.isFile) file.readLines().filter { it.isNotBlank() }.toSet() else emptySet()
    }

    private fun consumeNonce(nonce: String) {
        val previous = consumedNonces().toMutableList()
        if (nonce in previous) throw blocked("debug 测试 nonce 已消费")
        previous += nonce
        atomicWriter.writeText(File(filesDir, NONCE_FILE_NAME), previous.joinToString("\n"))
    }

    private fun writeState(
        session: Session,
        state: String,
        evidenceFile: String? = null,
        errorCode: String? = null,
    ) {
        val json = JSONObject()
            .put("run_id", session.command.runId)
            .put("confirm_id", session.confirmId)
            .put("state", state)
            .put("tool", session.command.tool)
            .put("time", Instant.ofEpochMilli(clock()).toString())
            .put("input_length", session.attempt.inputLength)
            .put("input_sha256", session.attempt.inputSha256)
        evidenceFile?.let { json.put("evidence_file", it) }
        session.cardVisible?.let { json.put("card_visible", it) }
        session.captureAttempts?.let { json.put("capture_attempts", it) }
        errorCode?.let { json.put("error_code", it) }
        atomicWriter.writeText(File(filesDir, STATE_FILE_NAME), json.toString())
    }

    private fun blocked(message: String): GatewayError = GatewayError(
        ErrorCode.E_BLOCKED,
        message,
        channel = "test-control",
        retryable = false,
    )
}

object TestControlFactory {
    fun create(context: Context): TestControl = DebugTestControl(
        filesDir = context.filesDir,
        cacheDir = context.cacheDir,
    )
}
