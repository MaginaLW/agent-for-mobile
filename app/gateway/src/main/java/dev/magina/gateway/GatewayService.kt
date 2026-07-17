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

        fun start(context: Context) {
            context.startForegroundService(Intent(context, GatewayService::class.java))
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, GatewayService::class.java))
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
        McpServer.start(Gateway.DEFAULT_PORT, Gateway.token)
        return START_STICKY
    }

    override fun onDestroy() {
        McpServer.stop()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
