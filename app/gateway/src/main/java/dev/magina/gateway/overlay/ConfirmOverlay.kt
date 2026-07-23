package dev.magina.gateway.overlay

import android.content.Context
import android.graphics.Color
import android.graphics.PixelFormat
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.Gravity
import android.view.ViewTreeObserver
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.GatewayError
import dev.magina.gateway.testing.TestConfirmationDecision
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit

/**
 * 统一安全门内部的确认悬浮窗（不暴露为 MCP 工具，harness §5.3 带内确认）。
 * 危险动作弹网关生成的卡片，人在手机上点头；超时抛 E_CONFIRM_TIMEOUT——大脑随即按
 * [AWAIT_CONFIRM] 协议输出暂停报告走带外兜底，传输层可替换、协议不动。
 */
object ConfirmOverlay {

    /** 供无障碍感知/动作面 fail-closed；只读，不提供任何机械确认入口。 */
    @Volatile
    var isAwaitingDecision: Boolean = false
        private set

    /** 阻塞调用方线程（工具线程，非主线程）直到 允许/拒绝/超时。 */
    @Synchronized
    fun ask(
        context: Context,
        actionDesc: String,
        timeoutMs: Long = 60_000,
        onShownBeforeButtonsEnabled: () -> Unit = {},
        onDecisionObserved: (TestConfirmationDecision) -> Unit = {},
    ): Boolean {
        if (Looper.myLooper() == Looper.getMainLooper()) throw GatewayError(
            ErrorCode.E_CHANNEL_DOWN,
            "统一安全门不能在主线程等待确认",
            channel = "overlay",
            fallback = "输出 [AWAIT_CONFIRM] 暂停报告，走带外两段式",
        )
        if (!Settings.canDrawOverlays(context)) throw GatewayError(
            ErrorCode.E_PERM_MISSING, "悬浮窗权限未授予，带内确认不可用",
            channel = "overlay", fallback = "直接输出 [AWAIT_CONFIRM] 走带外两段式",
        )

        val future = CompletableFuture<Boolean>()
        val cardShown = CompletableFuture<Unit>()
        val buttonsEnabled = CompletableFuture<Unit>()
        val readiness = ConfirmationReadinessGate()
        val main = Handler(Looper.getMainLooper())
        val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        isAwaitingDecision = true
        var view: LinearLayout? = null
        var pendingView: LinearLayout? = null
        var preDrawListener: ViewTreeObserver.OnPreDrawListener? = null
        var drawListener: ViewTreeObserver.OnDrawListener? = null
        var frameCommitCallback: Runnable? = null

        fun removeFrameFence(card: LinearLayout?) {
            val observer = card?.viewTreeObserver
            val preDraw = preDrawListener
            if (preDraw != null && observer?.isAlive == true) observer.removeOnPreDrawListener(preDraw)
            preDrawListener = null
            val listener = drawListener
            if (listener != null && observer?.isAlive == true) observer.removeOnDrawListener(listener)
            drawListener = null
            val commit = frameCommitCallback
            if (commit != null && observer?.isAlive == true) observer.unregisterFrameCommitCallback(commit)
            frameCommitCallback = null
        }

        fun mappedFailure(operation: String, cause: Throwable): GatewayError {
            val root = (cause as? java.util.concurrent.ExecutionException)?.cause ?: cause
            val code = if (root is SecurityException) ErrorCode.E_PERM_MISSING else ErrorCode.E_CHANNEL_DOWN
            return GatewayError(
                code,
                "确认悬浮窗${operation}失败：${root.javaClass.simpleName}: ${root.message.orEmpty()}",
                channel = "overlay",
                fallback = "输出 [AWAIT_CONFIRM] 暂停报告，走带外两段式",
            ).apply { initCause(root) }
        }

        fun dismissBlocking(): GatewayError? {
            val dismissed = CompletableFuture<Unit>()
            // 即使此刻 view 仍为空也必须排队：同一 main Handler 的 FIFO 保证 pending show 先执行，
            // cleanup 随后移除它，避免等待超时后迟到显示一张孤儿确认卡。
            val posted = main.post {
                val target = view
                if (target == null) {
                    readiness.fail()
                    isAwaitingDecision = false
                    dismissed.complete(Unit)
                } else try {
                    removeFrameFence(target)
                    readiness.fail()
                    wm.removeView(target)
                    view = null
                    isAwaitingDecision = false
                    dismissed.complete(Unit)
                } catch (removeError: Throwable) {
                    try {
                        removeFrameFence(target)
                        readiness.fail()
                        // 已在主线程；立即移除作为普通 removeView 失败后的最后 fail-closed 清理。
                        wm.removeViewImmediate(target)
                        view = null
                        isAwaitingDecision = false
                        dismissed.complete(Unit)
                    } catch (immediateError: Throwable) {
                        immediateError.addSuppressed(removeError)
                        // 保留 view 引用，明确表示清理未成功；调用方会收到结构化失败且不得执行动作。
                        dismissed.completeExceptionally(immediateError)
                    }
                }
            }
            if (!posted) return mappedFailure("移除", IllegalStateException("主线程 Handler 已停止"))
            return try {
                dismissed.get(2, TimeUnit.SECONDS)
                null
            } catch (error: java.util.concurrent.TimeoutException) {
                mappedFailure("移除", error)
            } catch (error: java.util.concurrent.ExecutionException) {
                mappedFailure("移除", error)
            } catch (error: InterruptedException) {
                Thread.currentThread().interrupt()
                mappedFailure("移除", error)
            }
        }

        val posted = main.post {
            try {
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
                            isEnabled = false
                            setOnClickListener { future.complete(false) }
                        }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
                        addView(Button(context).apply {
                            text = "允许本次"
                            isEnabled = false
                            setOnClickListener { future.complete(true) }
                        }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
                    })
                }
                pendingView = card
                val lp = WindowManager.LayoutParams(
                    WindowManager.LayoutParams.MATCH_PARENT,
                    WindowManager.LayoutParams.WRAP_CONTENT,
                    WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                    WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
                    PixelFormat.TRANSLUCENT,
                ).apply { gravity = Gravity.TOP }
                fun completeCommittedFrame() {
                    if (readiness.state() != ConfirmationReadinessGate.State.FRAME_COMMITTED) return
                    if (cardShown.complete(Unit)) {
                        card.post { removeFrameFence(card) }
                    }
                }
                val beforeDraw = object : ViewTreeObserver.OnPreDrawListener {
                    override fun onPreDraw(): Boolean {
                        if (!readiness.registerFrameCommit()) return true
                        if (!card.isHardwareAccelerated) {
                            readiness.fail()
                            cardShown.completeExceptionally(
                                IllegalStateException("确认卡窗口未启用硬件加速，无法建立 frame commit fence"),
                            )
                            return true
                        }
                        val observer = card.viewTreeObserver
                        if (!observer.isAlive) {
                            readiness.fail()
                            cardShown.completeExceptionally(IllegalStateException("确认卡 ViewTreeObserver 已失效"))
                            return true
                        }
                        try {
                            val committed = Runnable {
                                try {
                                    frameCommitCallback = null
                                    readiness.frameCommitted()
                                    completeCommittedFrame()
                                } catch (error: Throwable) {
                                    readiness.fail()
                                    cardShown.completeExceptionally(error)
                                }
                            }
                            frameCommitCallback = committed
                            observer.registerFrameCommitCallback(committed)
                            observer.removeOnPreDrawListener(this)
                            preDrawListener = null
                        } catch (error: Throwable) {
                            removeFrameFence(card)
                            readiness.fail()
                            cardShown.completeExceptionally(error)
                        }
                        return true
                    }
                }
                val listener = object : ViewTreeObserver.OnDrawListener {
                    override fun onDraw() {
                        readiness.observeDraw()
                        completeCommittedFrame()
                    }
                }
                preDrawListener = beforeDraw
                drawListener = listener
                card.viewTreeObserver.addOnPreDrawListener(beforeDraw)
                card.viewTreeObserver.addOnDrawListener(listener)
                wm.addView(card, lp)
                view = card
                pendingView = null
            } catch (error: Throwable) {
                removeFrameFence(view ?: pendingView)
                pendingView = null
                readiness.fail()
                cardShown.completeExceptionally(error)
                future.completeExceptionally(error)
            }
        }
        if (!posted) {
            val error = IllegalStateException("主线程 Handler 已停止")
            cardShown.completeExceptionally(error)
            future.completeExceptionally(error)
        }

        var result: Boolean? = null
        var failure: GatewayError? = null
        var waitingForHuman = false
        try {
            cardShown.get(2, TimeUnit.SECONDS)
            readiness.beginEvidence()
            // 可选的附加证据在首帧 draw fence 后同步准备；失败时按钮从未启用。
            onShownBeforeButtonsEnabled()
            readiness.evidenceReady()
            val enablePosted = main.post {
                val card = view
                if (card == null) {
                    buttonsEnabled.completeExceptionally(IllegalStateException("确认卡已不存在"))
                } else {
                    try {
                        readiness.enableButtons()
                        fun enableButtons(group: LinearLayout) {
                            for (i in 0 until group.childCount) {
                                when (val child = group.getChildAt(i)) {
                                    is Button -> child.isEnabled = true
                                    is LinearLayout -> enableButtons(child)
                                }
                            }
                        }
                        enableButtons(card)
                        buttonsEnabled.complete(Unit)
                    } catch (error: Throwable) {
                        readiness.fail()
                        buttonsEnabled.completeExceptionally(error)
                    }
                }
            }
            if (!enablePosted) throw IllegalStateException("主线程 Handler 已停止")
            buttonsEnabled.get(2, TimeUnit.SECONDS)
            waitingForHuman = true
            result = future.get(timeoutMs, TimeUnit.MILLISECONDS)
        } catch (e: java.util.concurrent.TimeoutException) {
            failure = if (waitingForHuman) {
                GatewayError(
                    ErrorCode.E_CONFIRM_TIMEOUT, "带内确认 ${timeoutMs / 1000}s 无人响应",
                    channel = "overlay",
                    fallback = "输出 [AWAIT_CONFIRM] 暂停报告，走带外两段式（harness §5.1）",
                )
            } else mappedFailure("显示或启用", e)
        } catch (error: java.util.concurrent.ExecutionException) {
            failure = mappedFailure("显示", error)
        } catch (error: InterruptedException) {
            Thread.currentThread().interrupt()
            failure = mappedFailure("等待", error)
        } catch (error: Throwable) {
            failure = if (error is GatewayError) error else mappedFailure("准备确认", error)
        }

        if (failure != null) readiness.fail()

        dismissBlocking()?.let { dismissError ->
            failure?.let { dismissError.addSuppressed(it) }
            throw dismissError
        }
        isAwaitingDecision = false
        val observedDecision = when {
            result == true -> TestConfirmationDecision.ALLOWED
            result == false -> TestConfirmationDecision.DENIED
            failure?.code == ErrorCode.E_CONFIRM_TIMEOUT -> TestConfirmationDecision.TIMED_OUT
            else -> null
        }
        observedDecision?.let { decision ->
            try {
                onDecisionObserved(decision)
            } catch (error: Throwable) {
                throw if (error is GatewayError) error else mappedFailure("记录确认状态", error)
            }
        }
        failure?.let { throw it }
        return result ?: throw mappedFailure("等待", IllegalStateException("确认结果为空"))
    }
}
