package dev.magina.gateway.notification

import android.app.Notification
import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log

/**
 * L3 通知只读监听服务：仅实时读取活动通知有限字段，不做持久化缓存，不传递 PendingIntent/RemoteInput。
 */
class GatewayNotificationListenerService : NotificationListenerService() {

    override fun onListenerConnected() {
        super.onListenerConnected()
        instance = this
        listenerConnected = true
    }

    override fun onListenerDisconnected() {
        listenerConnected = false
        if (instance === this) instance = null
        super.onListenerDisconnected()
    }

    override fun onDestroy() {
        listenerConnected = false
        if (instance === this) instance = null
        super.onDestroy()
    }

    companion object {
        private const val TAG = "gateway-notif"

        @Volatile
        var instance: GatewayNotificationListenerService? = null
            private set

        @Volatile
        var listenerConnected: Boolean = false
            private set

        fun isAccessGranted(context: Context): Boolean = runCatching {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
                ?: return false
            nm.isNotificationListenerAccessGranted(
                ComponentName(context, GatewayNotificationListenerService::class.java),
            )
        }.getOrDefault(false)

        fun isConnectedAndGranted(context: Context): Boolean =
            isAccessGranted(context) && listenerConnected && instance != null

        fun readActiveSnapshot(context: Context): Pair<NotificationAccessState, List<RawNotificationRecord>> {
            if (!isAccessGranted(context)) {
                return NotificationAccessState.PERMISSION_MISSING to emptyList()
            }
            val svc = instance
            if (!listenerConnected || svc == null) {
                return NotificationAccessState.SERVICE_DISCONNECTED to emptyList()
            }
            val active = try {
                svc.activeNotifications
            } catch (e: SecurityException) {
                Log.w(TAG, "activeNotifications denied", e)
                return NotificationAccessState.QUERY_FAILED_SECURITY to emptyList()
            } catch (e: RuntimeException) {
                Log.w(TAG, "activeNotifications failed", e)
                return NotificationAccessState.QUERY_FAILED_ERROR to emptyList()
            }
            if (active == null) {
                return NotificationAccessState.SERVICE_DISCONNECTED to emptyList()
            }

            val records = active.map(::toRawRecord)
            return NotificationAccessState.CONNECTED to records
        }

        private fun toRawRecord(sbn: StatusBarNotification): RawNotificationRecord {
            val notification = sbn.notification
            val extras = notification?.extras
            val title = extras?.getCharSequence(Notification.EXTRA_TITLE)?.toString()
            val bigText = extras?.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString()
            val text = if (!bigText.isNullOrBlank()) {
                bigText
            } else {
                extras?.getCharSequence(Notification.EXTRA_TEXT)?.toString()
            }
            val actions = notification?.actions
            val hasActions = !actions.isNullOrEmpty()
            val hasRemoteInput = actions?.any { !it.remoteInputs.isNullOrEmpty() } == true
            val pkg = sbn.packageName.orEmpty()
            val key = sbn.key ?: "$pkg:${sbn.id}:${sbn.postTime}"
            return RawNotificationRecord(
                key = key,
                packageName = pkg,
                postTime = sbn.postTime,
                title = title,
                text = text,
                visibility = notification?.visibility ?: Notification.VISIBILITY_PRIVATE,
                ongoing = sbn.isOngoing,
                hasActions = hasActions,
                hasRemoteInput = hasRemoteInput,
            )
        }
    }
}
