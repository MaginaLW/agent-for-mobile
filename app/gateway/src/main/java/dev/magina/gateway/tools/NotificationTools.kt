package dev.magina.gateway.tools

import dev.magina.gateway.Gateway
import dev.magina.gateway.notification.GatewayNotificationListenerService
import dev.magina.gateway.notification.NotificationAccessState
import dev.magina.gateway.notification.NotificationSnapshotPolicy
import dev.magina.gateway.notification.RawNotificationRecord
import org.json.JSONObject

/** L3 通知只读通道工具（严格只读；不传递 PendingIntent/RemoteInput，隔离网关自身与敏感黑名单通知）。 */
object NotificationTools {

    fun listNotifications(args: JSONObject): JSONObject = listNotifications(
        args = args,
        resolvePackage = Gateway.skills::resolvePackage,
        isBlockedApp = Gateway.skills::isBlockedApp,
        selfPackageName = Gateway.appContext.packageName,
        snapshotReader = { GatewayNotificationListenerService.readActiveSnapshot(Gateway.appContext) },
    )

    internal fun listNotifications(
        args: JSONObject,
        resolvePackage: (String) -> String,
        isBlockedApp: (String?) -> Boolean,
        selfPackageName: String,
        snapshotReader: () -> Pair<NotificationAccessState, List<RawNotificationRecord>>,
    ): JSONObject {
        val query = NotificationSnapshotPolicy.parseQuery(
            args = args,
            resolvePackage = resolvePackage,
            isBlockedApp = isBlockedApp,
        )
        val (state, records) = snapshotReader()
        return NotificationSnapshotPolicy.evaluate(
            state = state,
            records = records,
            query = query,
            selfPackageName = selfPackageName,
            isBlockedApp = isBlockedApp,
        )
    }
}
