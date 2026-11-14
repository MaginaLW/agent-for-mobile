package dev.magina.gateway.tools

import dev.magina.gateway.BuildConfig
import dev.magina.gateway.core.Audit
import dev.magina.gateway.core.Envelope
import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.GatewayError
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.util.concurrent.Callable
import java.util.concurrent.Executors

/** 运行生产共享分派/轮询/终态与真实 Envelope/Audit；分派和时钟为本地替身，不是真机验收。 */
class IntentSendObservationTest {
    @get:Rule val folder = TemporaryFolder()

    private class Clock {
        var now = 100L
        val sleeps = mutableListOf<Long>()
        fun sleep(ms: Long) { sleeps += ms; now += ms }
    }

    private fun observation(id: String, clock: Clock) = IntentSendObservation(42, "process-one", id) { clock.now }
    private fun record(value: IntentSendObservation) = JSONObject(value.auditNote().substringAfter(";r5_observation="))

    @Test fun `真实共享轮询超时只分派一次且响应和审计绑定同一次观测`() {
        val clock = Clock()
        val audit = Audit { folder.root }
        val id = audit.nextId()
        val observed = observation(id, clock)
        var dispatches = 0
        var reads = 0
        val error = assertThrows(GatewayError::class.java) {
            dispatchIntentSend(observed, { dispatches += 1 }) {
                val verified = pollForegroundLanding(3000, {
                    reads += 1
                    isAcceptableLanding("other", "other.Activity", "target", emptyList())
                }, { clock.now }, clock::sleep, observed)
                finishIntentSend("target", verified)
            }
        }
        val response = Envelope.err(error, JSONObject(), id)
        audit.write(id, "intent_send", JSONObject(), error.code.name, error.channel, clock.now - 100, observed.auditNote())
        val line = JSONObject(folder.root.listFiles()!!.single().readText().trim())
        val trace = JSONObject(line.getString("note").substringAfter(";r5_observation="))

        assertEquals(1, dispatches)
        assertEquals(15, reads)
        assertEquals(List(15) { 200L }, clock.sleeps)
        assertEquals("E_VERIFY_FAIL", response.getJSONObject("error").getString("code"))
        assertFalse(response.getJSONObject("error").getBoolean("retryable"))
        assertEquals(response.getString("audit_id"), line.getString("id"))
        assertEquals(id, trace.getString("audit_id"))
        assertEquals("E_VERIFY_FAIL", line.getString("result"))
        assertEquals("returned", trace.getString("dispatch"))
        assertEquals("timeout", trace.getString("poll"))
        assertEquals(100L, trace.getLong("poll_start_ms"))
        assertEquals(3100L, trace.getLong("poll_end_ms"))
        assertEquals(15, trace.getInt("checks"))
        assertEquals(42, trace.getInt("pid"))
        assertEquals("process-one", trace.getString("process_instance"))
    }

    @Test fun `正命中提前返回不再休眠且保持原verified结果`() {
        val clock = Clock()
        val observed = observation("a-hit", clock)
        var reads = 0
        val result = dispatchIntentSend(observed, {}) {
            val verified = pollForegroundLanding(3000, { ++reads == 3 }, { clock.now }, clock::sleep, observed)
            finishIntentSend("target", verified)
        }
        assertEquals("verified", result.getString("verification_status"))
        assertEquals(listOf(200L, 200L), clock.sleeps)
        assertEquals("hit", record(observed).getString("poll"))
        assertEquals(3, record(observed).getInt("checks"))
        assertEquals(500L, record(observed).getLong("poll_end_ms"))
    }

    @Test fun `无无障碍实例不进入实际轮询且不可冒充timeout`() {
        val clock = Clock()
        val observed = observation("a-absent", clock)
        val error = assertThrows(GatewayError::class.java) {
            dispatchIntentSend(observed, {}) {
                val verified = pollForegroundLanding(3000, null, { error("poll clock must not run") },
                    { error("must not sleep") }, observed)
                finishIntentSend("target", verified)
            }
        }
        assertEquals(ErrorCode.E_VERIFY_FAIL, error.code)
        assertEquals("no_a11y", record(observed).getString("poll"))
        assertEquals(0, record(observed).getInt("checks"))
        assertEquals(100L, record(observed).getLong("poll_start_ms"))
        assertEquals(100L, record(observed).getLong("poll_end_ms"))
    }

    @Test fun `读取中断保留原异常且不补成已完成检查或timeout`() {
        val clock = Clock()
        val observed = observation("a-interrupt", clock)
        val original = IllegalStateException("private-ui-marker")
        val actual = assertThrows(IllegalStateException::class.java) {
            dispatchIntentSend(observed, {}) {
                pollForegroundLanding(3000, { throw original }, { clock.now }, clock::sleep, observed)
                error("must not finish")
            }
        }
        assertSame(original, actual)
        assertEquals("returned", record(observed).getString("dispatch"))
        assertEquals("interrupted", record(observed).getString("poll"))
        assertEquals(0, record(observed).getInt("checks"))
        assertFalse(observed.auditNote().contains("private-ui-marker"))
    }

    @Test fun `分派异常不执行后续且只记录有限类别不含异常正文`() {
        val clock = Clock()
        val failures = listOf(
            GatewayError(ErrorCode.E_NOT_FOUND, "private-uri-marker") to "activity_not_found",
            SecurityException("private-extras-marker") to "security_exception",
            IllegalArgumentException("private-title-marker") to "exception",
            AssertionError("private-chat-marker") to "error",
        )
        for ((original, category) in failures) {
            val observed = observation("a-start", clock)
            var calls = 0
            val actual = assertThrows(Throwable::class.java) {
                dispatchIntentSend(observed, { calls += 1; throw original }) { error("must not verify") }
            }
            assertSame(original, actual)
            assertEquals(1, calls)
            assertEquals(category, record(observed).getString("dispatch"))
            assertEquals("not_entered", record(observed).getString("poll"))
            assertTrue(record(observed).isNull("dispatch_returned_ms"))
            assertFalse(observed.auditNote().contains("private-"))
        }
    }

    @Test fun `门前未触达与无目标均不形成负例超时`() {
        val clock = Clock()
        val untouched = observation("a-gate", clock)
        assertEquals("not_entered", record(untouched).getString("dispatch"))
        assertEquals("not_entered", record(untouched).getString("poll"))
        assertTrue(record(untouched).isNull("poll_start_ms"))
        val unknownTarget = observation("a-unknown", clock)
        val result = dispatchIntentSend(unknownTarget, {}) {
            unknownTarget.noTarget()
            finishIntentSend(null, null)
        }
        assertEquals("dispatched_unverified", result.getString("verification_status"))
        assertEquals("no_target", record(unknownTarget).getString("poll"))
    }

    @Test fun `研究时钟失效不改变业务结果或原始异常且缺失不报告timeout`() {
        val clock = Clock()
        val broken = IntentSendObservation(42, "process-one", "a-broken") { error("observer failure") }
        val result = dispatchIntentSend(broken, {}) {
            finishIntentSend("target", pollForegroundLanding(3000, { true }, { clock.now }, clock::sleep, broken))
        }
        assertEquals("verified", result.getString("verification_status"))
        assertFalse(record(broken).getBoolean("available"))
        assertEquals("unavailable", record(broken).getString("poll"))
        val original = SecurityException("business failure")
        assertSame(original, assertThrows(SecurityException::class.java) {
            dispatchIntentSend(broken, { throw original }) { error("must not run") }
        })
    }

    @Test fun `release及非目标工具关闭观测且不求取进程身份`() {
        fun create(debug: Boolean, tool: String) = createIntentSendObservation(debug, tool, "a-off",
            { error("pid must not be read") }, { error("instance must not be read") }, { error("clock must not run") })
        assertNull(create(false, "intent_send"))
        assertNull(create(true, "foreground_app"))
        if (!BuildConfig.DEBUG) assertNull(create(BuildConfig.DEBUG, "intent_send"))
        assertNull(createIntentSendObservation(true, "intent_send", "a-missing",
            { error("identity unavailable") }, { "never" }, { 0 }))
    }

    @Test fun `并发调用状态只属于各自的audit和进程实例`() {
        val executor = Executors.newFixedThreadPool(2)
        try {
            val jobs = (1..2).map { index -> Callable {
                val clock = Clock()
                val observed = IntentSendObservation(42, "process-$index", "a-$index") { clock.now }
                dispatchIntentSend(observed, {}) {
                    finishIntentSend("target", pollForegroundLanding(3000, { true }, { clock.now }, clock::sleep, observed))
                }
                record(observed)
            } }
            val records = executor.invokeAll(jobs).map { it.get() }
            records.forEachIndexed { index, trace ->
                assertEquals("a-${index + 1}", trace.getString("audit_id"))
                assertEquals("process-${index + 1}", trace.getString("process_instance"))
                assertEquals(1, trace.getInt("checks"))
            }
        } finally { executor.shutdownNow() }
    }
}
