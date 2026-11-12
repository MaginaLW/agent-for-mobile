package dev.magina.gateway

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/** 普通 BOOT_COMPLETED 在用户首次解锁后交付；不读取 Direct Boot 存储或启动界面。 */
class GatewayBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED || !GatewayService.resumeAfterBoot(context)) return
        try {
            context.startForegroundService(Intent(context, GatewayService::class.java))
        } catch (error: IllegalStateException) {
            Log.w("GatewayBoot", "系统未允许开机恢复网关，不重试", error)
        } catch (error: SecurityException) {
            Log.w("GatewayBoot", "开机恢复网关缺少系统许可，不重试", error)
        }
    }
}
