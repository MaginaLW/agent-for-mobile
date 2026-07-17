package dev.magina.gateway.overlay

import android.content.Context
import android.graphics.Color
import android.graphics.PixelFormat
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.Gravity
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.GatewayError
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit

/**
 * 确认层悬浮窗（spec §5.4 confirm 工具的 UI 载体，harness §5.3 带内确认）。
 * 危险动作弹卡片，人在手机上点头；超时抛 E_CONFIRM_TIMEOUT——大脑随即按
 * [AWAIT_CONFIRM] 协议输出暂停报告走带外兜底，传输层可替换、协议不动。
 */
object ConfirmOverlay {

    /** 阻塞调用方线程（工具线程，非主线程）直到 允许/拒绝/超时。 */
    fun ask(context: Context, actionDesc: String, timeoutMs: Long = 60_000): Boolean {
        if (!Settings.canDrawOverlays(context)) throw GatewayError(
            ErrorCode.E_PERM_MISSING, "悬浮窗权限未授予，带内确认不可用",
            channel = "overlay", fallback = "直接输出 [AWAIT_CONFIRM] 走带外两段式",
        )

        val future = CompletableFuture<Boolean>()
        val main = Handler(Looper.getMainLooper())
        val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        var view: LinearLayout? = null

        fun dismiss() {
            view?.let { v -> runCatching { wm.removeView(v) } }
            view = null
        }

        main.post {
            val card = LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                setBackgroundColor(Color.parseColor("#F2222222"))
                setPadding(48, 40, 48, 40)

                addView(TextView(context).apply {
                    text = "⚠ Agent 请求执行危险操作"
                    setTextColor(Color.parseColor("#FFB74D"))
                    textSize = 16f
                })
                addView(TextView(context).apply {
                    text = actionDesc
                    setTextColor(Color.WHITE)
                    textSize = 15f
                    setPadding(0, 16, 0, 24)
                })
                addView(LinearLayout(context).apply {
                    orientation = LinearLayout.HORIZONTAL
                    addView(Button(context).apply {
                        text = "拒绝"
                        setOnClickListener { future.complete(false) }
                    }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
                    addView(Button(context).apply {
                        text = "允许本次"
                        setOnClickListener { future.complete(true) }
                    }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
                })
            }
            val lp = WindowManager.LayoutParams(
                WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.WRAP_CONTENT,
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
                PixelFormat.TRANSLUCENT,
            ).apply { gravity = Gravity.BOTTOM }
            runCatching { wm.addView(card, lp); view = card }
                .onFailure { future.completeExceptionally(it) }
        }

        return try {
            future.get(timeoutMs, TimeUnit.MILLISECONDS)
        } catch (e: java.util.concurrent.TimeoutException) {
            throw GatewayError(
                ErrorCode.E_CONFIRM_TIMEOUT, "带内确认 ${timeoutMs / 1000}s 无人响应",
                channel = "overlay",
                fallback = "输出 [AWAIT_CONFIRM] 暂停报告，走带外两段式（harness §5.1）",
            )
        } finally {
            main.post { dismiss() }
        }
    }
}
