package dev.magina.gateway.notification

import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.GatewayError
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationSnapshotPolicyTest {

    private val aliases = mapOf(
        "微信" to "com.tencent.mm",
        "支付宝" to "com.eg.android.AlipayGphone",
    )
    private val blockedPrefixes = listOf("com.eg.android.AlipayGphone", "com.cmbchina.")
    private val resolvePackage: (String) -> String = { aliases[it] ?: it }
    private val isBlockedApp: (String?) -> Boolean = { pkg ->
        pkg != null && blockedPrefixes.any { pkg.startsWith(it) }
    }

    @Test
    fun `parseQuery accepts defaults, alias resolution, and boundary limits`() {
        val defaultQuery = NotificationSnapshotPolicy.parseQuery(JSONObject(), resolvePackage, isBlockedApp)
        assertNull(defaultQuery.targetPackage)
        assertEquals(20, defaultQuery.limit)

        val blankPkgQuery = NotificationSnapshotPolicy.parseQuery(
            JSONObject().put("package", "   ").put("limit", 1),
            resolvePackage,
            isBlockedApp,
        )
        assertNull(blankPkgQuery.targetPackage)
        assertEquals(1, blankPkgQuery.limit)

        val aliasQuery = NotificationSnapshotPolicy.parseQuery(
            JSONObject().put("package", " 微信 ").put("limit", 50),
            resolvePackage,
            isBlockedApp,
        )
        assertEquals("com.tencent.mm", aliasQuery.targetPackage)
        assertEquals(50, aliasQuery.limit)
    }

    @Test
    fun `parseQuery rejects undeclared keys, non-string package, and invalid limit`() {
        val unknownKey = expectGatewayError(ErrorCode.E_INVALID_ARG) {
            NotificationSnapshotPolicy.parseQuery(
                JSONObject().put("unexpected", true),
                resolvePackage,
                isBlockedApp,
            )
        }
        assertEquals("notif", unknownKey.channel)
        assertFalse(unknownKey.retryable)

        for (badPkg in listOf<Any>(123, true, JSONObject().put("a", 1))) {
            val err = expectGatewayError(ErrorCode.E_INVALID_ARG) {
                NotificationSnapshotPolicy.parseQuery(
                    JSONObject().put("package", badPkg),
                    resolvePackage,
                    isBlockedApp,
                )
            }
            assertEquals("notif", err.channel)
            assertFalse(err.retryable)
        }

        for (badLimit in listOf<Any>(0, -1, 51, true, "20", 20.5, 20.0)) {
            val err = expectGatewayError(ErrorCode.E_INVALID_ARG) {
                NotificationSnapshotPolicy.parseQuery(
                    JSONObject().put("limit", badLimit),
                    resolvePackage,
                    isBlockedApp,
                )
            }
            assertEquals("notif", err.channel)
            assertFalse(err.retryable)
        }
    }

    @Test
    fun `parseQuery blocks direct lookup of sensitive blacklisted app by package or alias`() {
        for (blockedInput in listOf("支付宝", "com.eg.android.AlipayGphone", "com.cmbchina.pb")) {
            val err = expectGatewayError(ErrorCode.E_BLOCKED) {
                NotificationSnapshotPolicy.parseQuery(
                    JSONObject().put("package", blockedInput),
                    resolvePackage,
                    isBlockedApp,
                )
            }
            assertEquals("safety", err.channel)
            assertFalse(err.retryable)
            assertTrue(err.message!!.contains("敏感黑名单"))
        }
    }

    @Test
    fun `evaluate maps permission missing, security error, disconnected, and query failure without fabricating empty list`() {
        val query = NotificationListQuery(targetPackage = null, limit = 20)

        for (permState in listOf(NotificationAccessState.PERMISSION_MISSING, NotificationAccessState.QUERY_FAILED_SECURITY)) {
            val err = expectGatewayError(ErrorCode.E_PERM_MISSING) {
                NotificationSnapshotPolicy.evaluate(
                    state = permState,
                    records = emptyList(),
                    query = query,
                    selfPackageName = "dev.magina.gateway",
                    isBlockedApp = isBlockedApp,
                )
            }
            assertEquals("notif", err.channel)
            assertFalse(err.retryable)
            assertTrue(err.fallback.isNotBlank())
        }

        for (downState in listOf(NotificationAccessState.SERVICE_DISCONNECTED, NotificationAccessState.QUERY_FAILED_ERROR)) {
            val err = expectGatewayError(ErrorCode.E_CHANNEL_DOWN) {
                NotificationSnapshotPolicy.evaluate(
                    state = downState,
                    records = emptyList(),
                    query = query,
                    selfPackageName = "dev.magina.gateway",
                    isBlockedApp = isBlockedApp,
                )
            }
            assertEquals("notif", err.channel)
            assertFalse(err.retryable)
            assertTrue(err.fallback.isNotBlank())
        }
    }

    @Test
    fun `evaluate returns genuine empty snapshot when connected with zero records`() {
        val result = NotificationSnapshotPolicy.evaluate(
            state = NotificationAccessState.CONNECTED,
            records = emptyList(),
            query = NotificationListQuery(targetPackage = null, limit = 20),
            selfPackageName = "dev.magina.gateway",
            isBlockedApp = isBlockedApp,
        )

        assertEquals(0, result.getJSONArray("notifications").length())
        assertEquals(0, result.getInt("count"))
        assertEquals(0, result.getInt("matched_count"))
        assertEquals(0, result.getInt("total_active"))
        assertEquals(0, result.getInt("blocked_filtered_count"))
        assertEquals(0, result.getInt("self_excluded_count"))
        assertFalse(result.getBoolean("truncated"))
        assertEquals(JSONObject.NULL, result.get("filter_package"))
        assertEquals(20, result.getInt("limit"))
        assertEquals("connected", result.getString("channel_state"))
    }

    @Test
    fun `evaluate isolates self and blocked notifications, redacts secret or empty content, folds whitespace, truncates, and sorts`() {
        val longTitle = "标题 " + "A".repeat(130)
        val longText = "正文\n\t多行   " + "B".repeat(260)
        val records = listOf(
            RawNotificationRecord(
                key = "0|dev.magina.gateway|1|null|1000",
                packageName = "dev.magina.gateway",
                postTime = 9000L,
                title = "危险动作确认",
                text = "一次性确认码不得泄露",
                visibility = 0,
                ongoing = false,
                hasActions = true,
                hasRemoteInput = false,
            ),
            RawNotificationRecord(
                key = "0|com.eg.android.AlipayGphone|2|null|1001",
                packageName = "com.eg.android.AlipayGphone",
                postTime = 8500L,
                title = "收款提醒",
                text = "100.00 元",
                visibility = 1,
                ongoing = false,
                hasActions = false,
                hasRemoteInput = false,
            ),
            RawNotificationRecord(
                key = "tie-key-alpha",
                packageName = "com.tencent.mm",
                postTime = 5000L,
                title = "张三\n  发来消息",
                text = "晚上\t一起吃饭吗",
                visibility = 0,
                ongoing = false,
                hasActions = true,
                hasRemoteInput = true,
            ),
            RawNotificationRecord(
                key = "tie-key-beta",
                packageName = "com.tencent.mm",
                postTime = 5000L,
                title = "私密锁屏内容",
                text = "不应出现在返回里",
                visibility = VISIBILITY_SECRET,
                ongoing = true,
                hasActions = false,
                hasRemoteInput = false,
            ),
            RawNotificationRecord(
                key = "empty-key",
                packageName = "com.xingin.xhs",
                postTime = 7000L,
                title = "  \n ",
                text = null,
                visibility = 1,
                ongoing = false,
                hasActions = false,
                hasRemoteInput = false,
            ),
            RawNotificationRecord(
                key = "long-key",
                packageName = "com.tencent.mm",
                postTime = 6000L,
                title = longTitle,
                text = longText,
                visibility = 1,
                ongoing = false,
                hasActions = true,
                hasRemoteInput = false,
            ),
        )

        val full = NotificationSnapshotPolicy.evaluate(
            state = NotificationAccessState.CONNECTED,
            records = records,
            query = NotificationListQuery(targetPackage = null, limit = 3),
            selfPackageName = "dev.magina.gateway",
            isBlockedApp = isBlockedApp,
        )

        assertEquals(6, full.getInt("total_active"))
        assertEquals(1, full.getInt("self_excluded_count"))
        assertEquals(1, full.getInt("blocked_filtered_count"))
        assertEquals(4, full.getInt("matched_count"))
        assertEquals(3, full.getInt("count"))
        assertTrue(full.getBoolean("truncated"))
        assertEquals("connected", full.getString("channel_state"))

        val items = full.getJSONArray("notifications")
        val first = items.getJSONObject(0)
        assertEquals("com.xingin.xhs", first.getString("package"))
        assertEquals(7000L, first.getLong("post_time"))
        assertTrue(first.getBoolean("content_redacted"))
        assertEquals("content_unavailable", first.getString("redaction_reason"))
        assertEquals("", first.getString("title"))
        assertEquals("", first.getString("text"))
        assertTrue(Regex("^n-[0-9a-f]{12}$").matches(first.getString("id")))

        val second = items.getJSONObject(1)
        assertEquals("com.tencent.mm", second.getString("package"))
        assertEquals(6000L, second.getLong("post_time"))
        assertFalse(second.getBoolean("content_redacted"))
        assertEquals(JSONObject.NULL, second.get("redaction_reason"))
        assertEquals(120, second.getString("title").length)
        assertTrue(second.getString("title").endsWith("…"))
        assertFalse(second.getString("text").contains("\n"))
        assertFalse(second.getString("text").contains("\t"))
        assertEquals(240, second.getString("text").length)
        assertTrue(second.getString("text").endsWith("…"))

        // 同时间戳按 id 升序
        val allSorted = NotificationSnapshotPolicy.evaluate(
            state = NotificationAccessState.CONNECTED,
            records = records,
            query = NotificationListQuery(targetPackage = "com.tencent.mm", limit = 20),
            selfPackageName = "dev.magina.gateway",
            isBlockedApp = isBlockedApp,
        )
        assertEquals("com.tencent.mm", allSorted.getString("filter_package"))
        assertEquals(3, allSorted.getInt("matched_count"))
        assertFalse(allSorted.getBoolean("truncated"))
        val mmItems = allSorted.getJSONArray("notifications")
        val tieA = mmItems.getJSONObject(1)
        val tieB = mmItems.getJSONObject(2)
        assertEquals(5000L, tieA.getLong("post_time"))
        assertEquals(5000L, tieB.getLong("post_time"))
        assertTrue(tieA.getString("id") < tieB.getString("id"))

        val secretItem = (0 until mmItems.length())
            .map { mmItems.getJSONObject(it) }
            .first { it.getBoolean("ongoing") }
        assertTrue(secretItem.getBoolean("content_redacted"))
        assertEquals("secret_visibility", secretItem.getString("redaction_reason"))
        assertEquals("", secretItem.getString("title"))
        assertEquals("", secretItem.getString("text"))
    }

    @Test
    fun `evaluate never leaks self notifications even when explicitly queried`() {
        val records = listOf(
            RawNotificationRecord(
                key = "0|dev.magina.gateway|1|null|1000",
                packageName = "dev.magina.gateway",
                postTime = 9000L,
                title = "审批提醒",
                text = "秘密动作",
                visibility = 1,
                ongoing = false,
                hasActions = true,
                hasRemoteInput = false,
            ),
        )
        val result = NotificationSnapshotPolicy.evaluate(
            state = NotificationAccessState.CONNECTED,
            records = records,
            query = NotificationListQuery(targetPackage = "dev.magina.gateway", limit = 20),
            selfPackageName = "dev.magina.gateway",
            isBlockedApp = isBlockedApp,
        )
        assertEquals(0, result.getInt("count"))
        assertEquals(0, result.getInt("matched_count"))
        assertEquals(1, result.getInt("self_excluded_count"))
    }

    private fun expectGatewayError(code: ErrorCode, block: () -> Unit): GatewayError {
        try {
            block()
        } catch (err: GatewayError) {
            assertEquals(code, err.code)
            return err
        }
        error("expected GatewayError($code)")
    }
}
