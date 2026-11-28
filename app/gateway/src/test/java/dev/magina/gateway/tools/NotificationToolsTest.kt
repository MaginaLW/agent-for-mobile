package dev.magina.gateway.tools

import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.GatewayError
import dev.magina.gateway.notification.NotificationAccessState
import dev.magina.gateway.notification.RawNotificationRecord
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationToolsTest {

    private val aliases = mapOf(
        "微信" to "com.tencent.mm",
        "支付宝" to "com.eg.android.AlipayGphone",
    )
    private val blockedPrefixes = listOf("com.eg.android.AlipayGphone")
    private val resolvePackage: (String) -> String = { aliases[it] ?: it }
    private val isBlockedApp: (String?) -> Boolean = { pkg ->
        pkg != null && blockedPrefixes.any { pkg.startsWith(it) }
    }

    @Test
    fun `listNotifications rejects blocked app query before calling snapshotReader`() {
        var readerCalls = 0
        val err = expectGatewayError(ErrorCode.E_BLOCKED) {
            NotificationTools.listNotifications(
                args = JSONObject().put("package", "支付宝"),
                resolvePackage = resolvePackage,
                isBlockedApp = isBlockedApp,
                selfPackageName = "dev.magina.gateway",
                snapshotReader = {
                    readerCalls += 1
                    NotificationAccessState.CONNECTED to emptyList()
                },
            )
        }
        assertEquals("safety", err.channel)
        assertEquals(0, readerCalls)
    }

    @Test
    fun `listNotifications propagates channel errors and returns filtered snapshot`() {
        val disconnectedErr = expectGatewayError(ErrorCode.E_CHANNEL_DOWN) {
            NotificationTools.listNotifications(
                args = JSONObject(),
                resolvePackage = resolvePackage,
                isBlockedApp = isBlockedApp,
                selfPackageName = "dev.magina.gateway",
                snapshotReader = { NotificationAccessState.SERVICE_DISCONNECTED to emptyList() },
            )
        }
        assertEquals("notif", disconnectedErr.channel)

        val ok = NotificationTools.listNotifications(
            args = JSONObject().put("package", "微信").put("limit", 5),
            resolvePackage = resolvePackage,
            isBlockedApp = isBlockedApp,
            selfPackageName = "dev.magina.gateway",
            snapshotReader = {
                NotificationAccessState.CONNECTED to listOf(
                    RawNotificationRecord(
                        key = "k-self",
                        packageName = "dev.magina.gateway",
                        postTime = 3000L,
                        title = "自产通知",
                        text = "应隔离",
                        visibility = 1,
                        ongoing = false,
                        hasActions = false,
                        hasRemoteInput = false,
                    ),
                    RawNotificationRecord(
                        key = "k-blocked",
                        packageName = "com.eg.android.AlipayGphone",
                        postTime = 2000L,
                        title = "黑名单",
                        text = "应过滤",
                        visibility = 1,
                        ongoing = false,
                        hasActions = false,
                        hasRemoteInput = false,
                    ),
                    RawNotificationRecord(
                        key = "k-mm",
                        packageName = "com.tencent.mm",
                        postTime = 1000L,
                        title = "文件传输助手",
                        text = "收到一条测试消息",
                        visibility = 0,
                        ongoing = false,
                        hasActions = true,
                        hasRemoteInput = false,
                    ),
                )
            },
        )
        assertEquals(1, ok.getInt("count"))
        assertEquals(1, ok.getInt("self_excluded_count"))
        assertEquals(1, ok.getInt("blocked_filtered_count"))
        assertEquals("com.tencent.mm", ok.getString("filter_package"))
        val item = ok.getJSONArray("notifications").getJSONObject(0)
        assertEquals("文件传输助手", item.getString("title"))
        assertTrue(item.getBoolean("has_actions"))
        assertFalse(item.getBoolean("has_remote_input"))
    }

    @Test
    fun `manifest declares protected GatewayNotificationListenerService and preserves security boundaries`() {
        val manifest = findManifestFile()
        val doc = DocumentBuilderFactory.newInstance().apply {
            isNamespaceAware = true
        }.newDocumentBuilder().parse(manifest)

        val permissions = doc.getElementsByTagName("uses-permission").let { nodes ->
            (0 until nodes.length).map {
                nodes.item(it).attributes.getNamedItemNS(ANDROID_NS, "name").nodeValue
            }.toSet()
        }
        assertFalse("不得声明 QUERY_ALL_PACKAGES", "android.permission.QUERY_ALL_PACKAGES" in permissions)
        assertFalse("不得声明 USE_FULL_SCREEN_INTENT", "android.permission.USE_FULL_SCREEN_INTENT" in permissions)

        val receivers = doc.getElementsByTagName("receiver")
        val confirmReceiver = (0 until receivers.length)
            .map { receivers.item(it) }
            .firstOrNull {
                it.attributes.getNamedItemNS(ANDROID_NS, "name")?.nodeValue == ".overlay.ConfirmDecisionReceiver"
            }
        assertNotNull("ConfirmDecisionReceiver 必须保持声明", confirmReceiver)
        assertEquals(
            "false",
            confirmReceiver!!.attributes.getNamedItemNS(ANDROID_NS, "exported")?.nodeValue,
        )

        val services = doc.getElementsByTagName("service")
        val notifService = (0 until services.length)
            .map { services.item(it) }
            .firstOrNull {
                it.attributes.getNamedItemNS(ANDROID_NS, "name")?.nodeValue == ".notification.GatewayNotificationListenerService"
            }
        assertNotNull("必须声明 GatewayNotificationListenerService", notifService)
        val attrs = notifService!!.attributes
        assertEquals("true", attrs.getNamedItemNS(ANDROID_NS, "exported")?.nodeValue)
        assertEquals("执行网关通知读取", attrs.getNamedItemNS(ANDROID_NS, "label")?.nodeValue)
        assertEquals(
            "android.permission.BIND_NOTIFICATION_LISTENER_SERVICE",
            attrs.getNamedItemNS(ANDROID_NS, "permission")?.nodeValue,
        )

        val childNodes = notifService.childNodes
        val intentActions = buildList {
            for (i in 0 until childNodes.length) {
                val child = childNodes.item(i)
                if (child.nodeName == "intent-filter") {
                    val sub = child.childNodes
                    for (j in 0 until sub.length) {
                        val actionNode = sub.item(j)
                        if (actionNode.nodeName == "action") {
                            add(actionNode.attributes.getNamedItemNS(ANDROID_NS, "name")?.nodeValue)
                        }
                    }
                }
            }
        }
        assertTrue(
            "必须声明 NotificationListenerService intent-filter",
            "android.service.notification.NotificationListenerService" in intentActions,
        )
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

    private fun findManifestFile(): File {
        val userDir = requireNotNull(System.getProperty("user.dir")) { "JVM 未提供 user.dir" }
        var cursor: File? = File(userDir).absoluteFile
        while (cursor != null) {
            listOf(
                File(cursor, "gateway/src/main/AndroidManifest.xml"),
                File(cursor, "app/gateway/src/main/AndroidManifest.xml"),
            ).firstOrNull(File::isFile)?.let { return it }
            cursor = cursor.parentFile
        }
        error("找不到 AndroidManifest.xml（user.dir=$userDir）")
    }

    private companion object {
        const val ANDROID_NS = "http://schemas.android.com/apk/res/android"
    }
}
