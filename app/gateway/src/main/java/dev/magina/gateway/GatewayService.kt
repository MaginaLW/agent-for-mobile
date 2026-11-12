package dev.magina.gateway

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import dev.magina.gateway.mcp.McpServer

/** 前台服务：承载嵌入式 MCP server（顺带满足国产 ROM 保活，spec §10）。 */
class GatewayService : Service() {

    companion object {
        private const val CHANNEL_ID = "gateway"
        private const val NOTIF_ID = 1
        private const val RESUME_AFTER_BOOT = "resume_after_boot"

        var bootChoiceSaveUnconfirmed = false
            private set

        fun resumeAfterBoot(context: Context): Boolean =
            !bootChoiceSaveUnconfirmed && context.getSharedPreferences("gateway", Context.MODE_PRIVATE)
                .getBoolean(RESUME_AFTER_BOOT, false)

        private fun rememberRunChoice(context: Context, enabled: Boolean) {
            // commit失败时SharedPreferences的内存也可能已变化；UI不能拿它冒充落盘成功。
            bootChoiceSaveUnconfirmed = true
            check(
                context.getSharedPreferences("gateway", Context.MODE_PRIVATE)
                    .edit().putBoolean(RESUME_AFTER_BOOT, enabled).commit(),
            ) { "网关开机恢复选择保存失败" }
            bootChoiceSaveUnconfirmed = false
        }

        fun start(context: Context) {
            rememberRunChoice(context, true)
            context.startForegroundService(Intent(context, GatewayService::class.java))
        }

        fun stop(context: Context) {
            try {
                rememberRunChoice(context, false)
            } finally {
                // 即使保存失败也先停止当前服务；错误仍向调用方报告，不假称下次开机已禁用。
                context.stopService(Intent(context, GatewayService::class.java))
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        Gateway.init(this)
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "执行网关", NotificationManager.IMPORTANCE_LOW),
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notif = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("执行网关运行中")
            .setContentText("MCP server: 127.0.0.1:${Gateway.DEFAULT_PORT}/mcp")
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setOngoing(true)
            .build()
        startForeground(NOTIF_ID, notif)
        McpServer.start(Gateway.DEFAULT_PORT, Gateway.token())
        return START_STICKY
    }

    override fun onDestroy() {
        McpServer.stop()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
