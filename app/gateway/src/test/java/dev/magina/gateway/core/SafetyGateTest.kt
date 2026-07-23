package dev.magina.gateway.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.fail
import org.junit.Test

class SafetyGateTest {
    private val args = JSONObject().put("key", "enter")
    private val inputEvidence = InputCommitEvidence(
        commitId = 1,
        preview = "P0 安全硬门测试",
        length = "P0 安全硬门测试".length,
        sha256 = InputCommitEvidence.sha256("P0 安全硬门测试"),
        focusedInputId = "chat-input",
        committedAtMs = 1_000,
        expiresAtMs = 61_000,
    )
    private val preparedTarget = PreparedTargetEvidence(
        preparedId = 1,
        label = "文件传输助手",
        packageName = "com.tencent.mm",
        focusedInputId = "chat-input",
        bounds = "[10,20][100,80]",
        imeSessionId = "ime|0123456789abcdef01234567",
        preparedAtMs = 1_000,
        expiresAtMs = 61_000,
    )
    private val initialContext = SafetyContext(
        packageName = "com.tencent.mm",
        activityName = ".ui.LauncherUI",
        revision = 7,
        target = SafetyTarget(
            focusedInputId = "chat-input",
            focusedInputBounds = "[10,20][100,80]",
            imeSessionId = "ime|0123456789abcdef01234567",
            inputCommitEvidence = inputEvidence,
            preparedTargetEvidence = preparedTarget,
        ),
    )

    @Test
    fun `rejected confirmation never calls executor or failure recorder`() {
        var executorCalls = 0
        var failureRecords = 0
        val gate = SafetyGate(
            policy = SafetyPolicy(),
            confirmer = { false },
            contextProvider = { initialContext },
            onExecutionFailure = { failureRecords++ },
        )

        val error = expectGatewayError(ErrorCode.E_BLOCKED) {
            gate.execute("press_key", Level.W, args) { _, _ ->
                executorCalls++
                JSONObject()
            }
        }

        assertEquals(ErrorCode.E_BLOCKED, error.code)
        assertEquals(0, executorCalls)
        assertEquals(0, failureRecords)
    }

    @Test
    fun `confirmation timeout never calls executor or failure recorder`() {
        var executorCalls = 0
        var failureRecords = 0
        val timeout = GatewayError(ErrorCode.E_CONFIRM_TIMEOUT, "等待确认超时")
        val gate = SafetyGate(
            policy = SafetyPolicy(),
            confirmer = { throw timeout },
            contextProvider = { initialContext },
            onExecutionFailure = { failureRecords++ },
        )

        val error = expectGatewayError(ErrorCode.E_CONFIRM_TIMEOUT) {
            gate.execute("press_key", Level.W, args) { _, _ ->
                executorCalls++
                JSONObject()
            }
        }

        assertSame(timeout, error)
        assertEquals(0, executorCalls)
        assertEquals(0, failureRecords)
    }

    @Test
    fun `allowed confirmation with unchanged context calls executor exactly once`() {
        var executorCalls = 0
        var successCalls = 0
        val gate = SafetyGate(
            policy = SafetyPolicy(),
            confirmer = { true },
            contextProvider = { initialContext },
            onExecutionFailure = { fail("成功执行不得记录失败") },
            afterExecutionSuccess = { tool, _ ->
                assertEquals("press_key", tool)
                successCalls++
            },
        )

        val result = gate.execute("press_key", Level.W, args) { _, _ ->
            executorCalls++
            "executed"
        }

        assertEquals("executed", result)
        assertEquals(1, executorCalls)
        assertEquals(1, successCalls)
    }

    @Test
    fun `after confirmation hook runs only after allow and before final context read`() {
        val order = mutableListOf<String>()
        var reads = 0
        val gate = SafetyGate(
            policy = SafetyPolicy(),
            confirmer = { order += "allowed-overlay-removed"; true },
            contextProvider = {
                reads++
                order += "context-$reads"
                initialContext
            },
            onExecutionFailure = { fail("成功执行不得记录失败") },
            afterConfirmationAllowed = { tool, frozenArgs, before ->
                assertEquals("press_key", tool)
                assertEquals("enter", frozenArgs.getString("key"))
                assertSame(initialContext, before)
                order += "hook"
            },
        )

        gate.execute("press_key", Level.W, args) { _, _ -> order += "executor" }

        assertEquals(
            listOf("context-1", "allowed-overlay-removed", "hook", "context-2", "executor"),
            order,
        )
    }

    @Test
    fun `after confirmation hook never runs after denial`() {
        var hookCalls = 0
        val gate = SafetyGate(
            policy = SafetyPolicy(),
            confirmer = { false },
            contextProvider = { initialContext },
            onExecutionFailure = { fail("拒绝不得记录执行失败") },
            afterConfirmationAllowed = { _, _, _ -> hookCalls++ },
        )

        expectGatewayError(ErrorCode.E_BLOCKED) {
            gate.execute("press_key", Level.W, args) { _, _ -> fail("不得执行") }
        }

        assertEquals(0, hookCalls)
    }

    @Test
    fun `hook induced foreground change still fails through real context validation`() {
        var current = initialContext
        var executorCalls = 0
        val gate = SafetyGate(
            policy = SafetyPolicy(),
            confirmer = { true },
            contextProvider = { current },
            onExecutionFailure = { fail("上下文失效不得记录执行失败") },
            afterConfirmationAllowed = { _, _, _ ->
                current = initialContext.copy(
                    packageName = "com.android.launcher",
                    activityName = ".Launcher",
                )
            },
        )

        expectGatewayError(ErrorCode.E_STALE_REF) {
            gate.execute("press_key", Level.W, args) { _, _ -> executorCalls++ }
        }

        assertEquals(0, executorCalls)
    }

    @Test
    fun `foreground package change after confirmation rejects as stale`() {
        assertContextChangeIsStale(initialContext.copy(packageName = "com.android.launcher"))
    }

    @Test
    fun `foreground activity change after confirmation rejects as stale`() {
        assertContextChangeIsStale(initialContext.copy(activityName = ".plugin.SnsTimeLineUI"))
    }

    @Test
    fun `dynamic target signature change after confirmation rejects as stale`() {
        assertContextChangeIsStale(
            initialContext.copy(
                target = SafetyTarget(
                    focusedInputId = "search-input",
                    focusedInputBounds = "[10,20][100,80]",
                    imeSessionId = "ime|0123456789abcdef01234567",
                    inputCommitEvidence = inputEvidence.copy(focusedInputId = "search-input"),
                    preparedTargetEvidence = preparedTarget.copy(focusedInputId = "search-input"),
                ),
            ),
        )
    }

    @Test
    fun `missing input commit evidence blocks enter before confirmation`() {
        var confirmerCalls = 0
        var executorCalls = 0
        val gate = SafetyGate(
            policy = SafetyPolicy(),
            confirmer = { confirmerCalls++; true },
            contextProvider = {
                initialContext.copy(target = SafetyTarget(focusedInputId = "chat-input"))
            },
            onExecutionFailure = { fail("门前阻断不得记录执行失败") },
        )

        expectGatewayError(ErrorCode.E_BLOCKED) {
            gate.execute("press_key", Level.W, args) { _, _ -> executorCalls++ }
        }

        assertEquals(0, confirmerCalls)
        assertEquals(0, executorCalls)
    }

    @Test
    fun `input commit replacement after confirmation rejects as stale`() {
        assertContextChangeIsStale(
            initialContext.copy(
                target = initialContext.target!!.copy(
                    inputCommitEvidence = inputEvidence.copy(commitId = 2),
                ),
            ),
        )
    }

    @Test
    fun `expired input commit evidence after confirmation rejects as stale`() {
        assertContextChangeIsStale(
            initialContext.copy(target = initialContext.target!!.copy(inputCommitEvidence = null)),
        )
    }

    @Test
    fun `same focused input changed by app after confirmation rejects as stale`() {
        var reads = 0
        var readableText: String? = "P0 安全硬门测试"
        var now = 1_000L
        val store = InputCommitEvidenceStore(ttlMs = 60_000, clock = { now })
        store.record(readableText!!, "chat-input")
        val gate = SafetyGate(
            policy = SafetyPolicy(),
            confirmer = {
                readableText = "App 自动改写后的内容"
                true
            },
            contextProvider = {
                reads++
                initialContext.copy(
                    target = SafetyTarget(
                        focusedInputId = "chat-input",
                        focusedInputBounds = "[10,20][100,80]",
                        imeSessionId = "ime|0123456789abcdef01234567",
                        inputCommitEvidence = store.current("chat-input", readableText),
                        preparedTargetEvidence = preparedTarget,
                    ),
                )
            },
            onExecutionFailure = { fail("上下文失效不得记录执行失败") },
        )

        expectGatewayError(ErrorCode.E_STALE_REF) {
            gate.execute("press_key", Level.W, args) { _, _ -> fail("不得执行") }
        }

        assertEquals(2, reads)
    }

    @Test
    fun `prepared target replacement expiry focus and bounds changes reject as stale`() {
        listOf(
            initialContext.target!!.copy(
                preparedTargetEvidence = preparedTarget.copy(preparedId = 2),
            ),
            initialContext.target!!.copy(preparedTargetEvidence = null),
            initialContext.target!!.copy(
                focusedInputId = "other-input",
                inputCommitEvidence = inputEvidence.copy(focusedInputId = "other-input"),
                preparedTargetEvidence = preparedTarget.copy(focusedInputId = "other-input"),
            ),
            initialContext.target!!.copy(
                focusedInputBounds = "[0,0][1,1]",
                preparedTargetEvidence = preparedTarget.copy(bounds = "[0,0][1,1]"),
            ),
            initialContext.target!!.copy(
                imeSessionId = "ime|fedcba9876543210fedcba98",
                preparedTargetEvidence = preparedTarget.copy(
                    imeSessionId = "ime|fedcba9876543210fedcba98",
                ),
            ),
        ).forEach { changed ->
            assertContextChangeIsStale(initialContext.copy(target = changed))
        }
    }

    @Test
    fun `prepared target is not cleared when executor fails`() {
        var successCalls = 0
        val gate = SafetyGate(
            policy = SafetyPolicy(),
            confirmer = { true },
            contextProvider = { initialContext },
            onExecutionFailure = {},
            afterExecutionSuccess = { _, _ -> successCalls++ },
        )

        expectGatewayError(ErrorCode.E_VERIFY_FAIL) {
            gate.execute("press_key", Level.W, args) { _, _ ->
                throw GatewayError(ErrorCode.E_VERIFY_FAIL, "failed")
            }
        }

        assertEquals(0, successCalls)
    }

    @Test
    fun `revision change alone does not invalidate confirmed context`() {
        var contextReads = 0
        var executorCalls = 0
        val gate = SafetyGate(
            policy = SafetyPolicy(),
            confirmer = { true },
            contextProvider = {
                contextReads++
                initialContext.copy(revision = initialContext.revision + contextReads)
            },
            onExecutionFailure = { fail("revision 变化不是执行失败") },
        )

        gate.execute("press_key", Level.W, args) { _, _ -> executorCalls++ }

        assertEquals(1, executorCalls)
    }

    @Test
    fun `argument mutation during confirmation rejects as stale`() {
        var executorCalls = 0
        var failureRecords = 0
        val mutableArgs = JSONObject().put("key", "enter")
        val gate = SafetyGate(
            policy = SafetyPolicy(),
            confirmer = {
                mutableArgs.put("key", "home")
                true
            },
            contextProvider = { initialContext },
            onExecutionFailure = { failureRecords++ },
        )

        expectGatewayError(ErrorCode.E_STALE_REF) {
            gate.execute("press_key", Level.W, mutableArgs) { _, _ -> executorCalls++ }
        }

        assertEquals(0, executorCalls)
        assertEquals(0, failureRecords)
    }

    @Test
    fun `ui target text description bounds and source are bound after confirmation`() {
        val uiArgs = JSONObject().put("ref", "send-button").put("action", "click")
        val target = SafetyTarget(
            ref = "send-button",
            text = "发送",
            description = "发送消息",
            bounds = "[900,1800][1080,1920]",
            source = "a11y",
        )
        val before = initialContext.copy(target = target)
        listOf(
            target.copy(ref = "other-button"),
            target.copy(text = "删除"),
            target.copy(description = "发送文件"),
            target.copy(bounds = "[0,0][10,10]"),
            target.copy(source = "ocr"),
        ).forEach { changedTarget ->
            var reads = 0
            var executorCalls = 0
            val gate = SafetyGate(
                policy = SafetyPolicy(),
                confirmer = { true },
                contextProvider = {
                    reads++
                    if (reads == 1) before else before.copy(target = changedTarget)
                },
                onExecutionFailure = { fail("上下文失效不得记录执行失败") },
            )

            expectGatewayError(ErrorCode.E_STALE_REF) {
                gate.execute("ui_action", Level.W, uiArgs) { _, _ -> executorCalls++ }
            }
            assertEquals(0, executorCalls)
        }
    }

    @Test
    fun `executor failure is recorded exactly once`() {
        var failureRecords = 0
        val executionError = GatewayError(ErrorCode.E_VERIFY_FAIL, "执行失败")
        val gate = SafetyGate(
            policy = SafetyPolicy(),
            confirmer = { true },
            contextProvider = { initialContext },
            onExecutionFailure = { failureRecords++ },
        )

        val actual = expectGatewayError(ErrorCode.E_VERIFY_FAIL) {
            gate.execute("press_key", Level.W, args) { _, _ -> throw executionError }
        }

        assertSame(executionError, actual)
        assertEquals(1, failureRecords)
    }

    @Test
    fun `stale error at final execution point is not recorded as execution failure`() {
        var failureRecords = 0
        val stale = GatewayError(ErrorCode.E_STALE_REF, "最终执行点目标已变化")
        val gate = SafetyGate(
            policy = SafetyPolicy(),
            confirmer = { true },
            contextProvider = { initialContext },
            onExecutionFailure = { failureRecords++ },
        )

        val actual = expectGatewayError(ErrorCode.E_STALE_REF) {
            gate.execute("press_key", Level.W, args) { _, _ -> throw stale }
        }

        assertSame(stale, actual)
        assertEquals(0, failureRecords)
    }

    @Test
    fun `executor receives frozen argument snapshot`() {
        val original = JSONObject().put("key", "home")
        var executorKey = ""
        val gate = SafetyGate(
            policy = SafetyPolicy(),
            confirmer = { fail("home 不应触发确认"); false },
            contextProvider = { evidenceArgs ->
                evidenceArgs.put("key", "del")
                original.put("key", "enter")
                initialContext
            },
            onExecutionFailure = { fail("成功执行不得记录失败") },
        )

        gate.execute("press_key", Level.W, original) { frozenArgs, _ ->
            executorKey = frozenArgs.getString("key")
        }

        assertEquals("enter", original.getString("key"))
        assertEquals("home", executorKey)
    }

    @Test
    fun `unknown foreground blocks Level W before confirmation and execution`() {
        assertUnknownForegroundBlocked(Level.W)
    }

    @Test
    fun `unknown foreground blocks Level D before confirmation and execution`() {
        assertUnknownForegroundBlocked(Level.D)
    }

    @Test
    fun `unknown foreground still allows Level R execution`() {
        var confirmerCalls = 0
        var executorCalls = 0
        var failureRecords = 0
        val unknown = SafetyContext("fallback.package", "", -1, foregroundKnown = false)
        val gate = SafetyGate(
            policy = SafetyPolicy(),
            confirmer = { confirmerCalls++; false },
            contextProvider = { unknown },
            onExecutionFailure = { failureRecords++ },
        )

        val result = gate.execute("device_info", Level.R, JSONObject()) { _, context ->
            executorCalls++
            context.foregroundKnown
        }

        assertEquals(false, result)
        assertEquals(0, confirmerCalls)
        assertEquals(1, executorCalls)
        assertEquals(0, failureRecords)
    }

    @Test
    fun `foreground becoming unknown after confirmation blocks before execution`() {
        var contextReads = 0
        var confirmerCalls = 0
        var executorCalls = 0
        var failureRecords = 0
        val unknown = initialContext.copy(foregroundKnown = false)
        val gate = SafetyGate(
            policy = SafetyPolicy(),
            confirmer = { confirmerCalls++; true },
            contextProvider = {
                contextReads++
                if (contextReads == 1) initialContext else unknown
            },
            onExecutionFailure = { failureRecords++ },
        )

        val error = expectGatewayError(ErrorCode.E_BLOCKED) {
            gate.execute("press_key", Level.W, args) { _, _ -> executorCalls++ }
        }

        assertEquals("safety", error.channel)
        assertEquals(2, contextReads)
        assertEquals(1, confirmerCalls)
        assertEquals(0, executorCalls)
        assertEquals(0, failureRecords)
    }

    private fun assertUnknownForegroundBlocked(level: Level) {
        var confirmerCalls = 0
        var contextReads = 0
        var executorCalls = 0
        var failureRecords = 0
        val unknown = SafetyContext("fallback.package", "", -1, foregroundKnown = false)
        val gate = SafetyGate(
            policy = SafetyPolicy(),
            confirmer = { confirmerCalls++; true },
            contextProvider = { contextReads++; unknown },
            onExecutionFailure = { failureRecords++ },
        )

        val error = expectGatewayError(ErrorCode.E_BLOCKED) {
            gate.execute("unknown_foreground_test", level, JSONObject()) { _, _ ->
                executorCalls++
            }
        }

        assertEquals("safety", error.channel)
        assertEquals(1, contextReads)
        assertEquals(0, confirmerCalls)
        assertEquals(0, executorCalls)
        assertEquals(0, failureRecords)
    }

    private fun assertContextChangeIsStale(changedContext: SafetyContext) {
        var contextReads = 0
        var executorCalls = 0
        var failureRecords = 0
        val gate = SafetyGate(
            policy = SafetyPolicy(),
            confirmer = { true },
            contextProvider = {
                contextReads++
                if (contextReads == 1) initialContext else changedContext
            },
            onExecutionFailure = { failureRecords++ },
        )

        val error = expectGatewayError(ErrorCode.E_STALE_REF) {
            gate.execute("press_key", Level.W, args) { _, _ ->
                executorCalls++
                JSONObject()
            }
        }

        assertEquals(ErrorCode.E_STALE_REF, error.code)
        assertEquals(0, executorCalls)
        assertEquals(0, failureRecords)
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
