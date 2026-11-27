package dev.magina.gateway.overlay

import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Color
import android.graphics.PixelFormat
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.ViewTreeObserver
import android.view.WindowInsets
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.core.content.ContextCompat
import dev.magina.gateway.core.ApprovalChannel
import dev.magina.gateway.core.ApprovalChannelRecorder
import dev.magina.gateway.core.ConfirmApprovalArbiter
import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.GatewayError
import dev.magina.gateway.core.SafetyFallbacks
import dev.magina.gateway.testing.TestConfirmationDecision
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.roundToLong

/**
 * 确认卡窗口宿主。无障碍服务可用时优先用 `TYPE_ACCESSIBILITY_OVERLAY`，尝试绕开 vivo 对后台
 * `TYPE_APPLICATION_OVERLAY` 的静默拦截；无障碍服务不可用时回退应用悬浮窗。
 */
data class ConfirmOverlayWindowHost(
    val context: Context,
)

internal enum class ConfirmOverlayWindowKind { ACCESSIBILITY_OVERLAY, APPLICATION_OVERLAY, UNAVAILABLE }

internal fun chooseConfirmOverlayWindowKind(
    accessibilityHostAvailable: Boolean,
    canDrawOverlays: Boolean,
): ConfirmOverlayWindowKind = when {
    accessibilityHostAvailable -> ConfirmOverlayWindowKind.ACCESSIBILITY_OVERLAY
    canDrawOverlays -> ConfirmOverlayWindowKind.APPLICATION_OVERLAY
    else -> ConfirmOverlayWindowKind.UNAVAILABLE
}

internal const val CONFIRM_OVERLAY_MAX_WIDTH_DP: Int = 720
internal const val CONFIRM_OVERLAY_BOTTOM_OFFSET_DP: Int = 12
internal const val CONFIRM_OVERLAY_HORIZONTAL_MARGIN_DP: Int = 16
internal const val CONFIRM_OVERLAY_MAX_HEIGHT_FRACTION: Double = 0.50
private const val CONFIRM_OVERLAY_CARD_VERTICAL_PADDING_PX: Int = 80
private const val CONFIRM_OVERLAY_CHROME_RESERVE_DP: Int = 80
private const val CONFIRM_OVERLAY_MIN_BODY_HEIGHT_DP: Int = 80

/**
 * 锁屏/亮屏系统广播接收器标志。
 *
 * `ACTION_USER_PRESENT` 由 `com.android.systemui`（非 `Process.SYSTEM_UID`）发出；
 * 在 targetSdk 34+ 上使用 `RECEIVER_NOT_EXPORTED` 会导致该解锁广播被系统静默跳过。
 * 三个监听 action 均为框架 `<protected-broadcast>`，且回调仍严格白名单过滤并实时复核
 * `KeyguardManager` / `PowerManager`。
 */
internal const val CONFIRM_OVERLAY_LOCK_RECEIVER_FLAGS: Int = ContextCompat.RECEIVER_EXPORTED

internal data class ConfirmOverlayWindowLayout(
    val width: Int,
    val height: Int,
    val gravity: Int,
    val yOffsetPx: Int,
    val flags: Int,
    val fitSystemBarsAndCutout: Boolean,
    val fitIme: Boolean,
    val maxBodyHeightPx: Int?,
)

/**
 * 确认卡窗口布局策略（纯函数，JVM 可测）。
 *
 * `TYPE_ACCESSIBILITY_OVERLAY` 的窗口层级高于状态栏与通知中心：
 * 1. 锚定底部居中并仅避让系统栏与刘海，**不避让 IME**——若避让输入法，微信键盘展开时会把底部卡片
 *    直接顶回屏幕上沿，再次遮住通知中心；确认期间用户不输入，覆盖软键盘区不影响 `FLAG_NOT_FOCUSABLE`
 *    的焦点与 InputConnection 身份。
 * 2. 限制正文滚动区最大高度，确保整张卡片始终留在屏幕下半区、顶部通知中心与会话标题栏恒可触达，
 *    同时保持标题与「拒绝 / 允许本次」按钮始终固定可见。
 * 3. 宽屏平板限制最大宽度为 `720dp`，避免铺满全宽。
 */
internal fun confirmOverlayWindowLayout(
    displayWidthPx: Int,
    displayHeightPx: Int = 0,
    density: Float,
): ConfirmOverlayWindowLayout {
    val validDensity = density.isFinite() && density > 0f
    val safeDensity = if (validDensity) density.toDouble() else 1.0
    val width = if (!validDensity || displayWidthPx <= 0) {
        WindowManager.LayoutParams.MATCH_PARENT
    } else {
        val maxWidthLong = (CONFIRM_OVERLAY_MAX_WIDTH_DP.toDouble() * safeDensity).roundToLong()
        val marginLong = (CONFIRM_OVERLAY_HORIZONTAL_MARGIN_DP.toDouble() * safeDensity).roundToLong()
        if (maxWidthLong in 1L..Int.MAX_VALUE.toLong() &&
            marginLong in 0L..Int.MAX_VALUE.toLong() &&
            displayWidthPx.toLong() > maxWidthLong + marginLong * 2L
        ) {
            maxWidthLong.toInt()
        } else {
            WindowManager.LayoutParams.MATCH_PARENT
        }
    }
    val rawOffsetLong = (CONFIRM_OVERLAY_BOTTOM_OFFSET_DP.toDouble() * safeDensity)
        .roundToLong()
        .coerceIn(1L, Int.MAX_VALUE.toLong())
    val bottomOffsetPx = if (displayHeightPx > 0) {
        rawOffsetLong.coerceAtMost((displayHeightPx / 8).coerceAtLeast(1).toLong()).toInt()
    } else {
        rawOffsetLong.toInt()
    }
    val maxBodyHeightPx = if (displayHeightPx > 0) {
        val maxCardHeightPx = (displayHeightPx.toDouble() * CONFIRM_OVERLAY_MAX_HEIGHT_FRACTION)
            .roundToLong()
            .coerceIn(1L, displayHeightPx.toLong())
        val chromeLong = CONFIRM_OVERLAY_CARD_VERTICAL_PADDING_PX.toLong() +
            (CONFIRM_OVERLAY_CHROME_RESERVE_DP.toDouble() * safeDensity).roundToLong().coerceAtLeast(0L)
        val minBodyLong = (CONFIRM_OVERLAY_MIN_BODY_HEIGHT_DP.toDouble() * safeDensity)
            .roundToLong()
            .coerceIn(1L, (displayHeightPx / 3).coerceAtLeast(1).toLong())
        (maxCardHeightPx - chromeLong)
            .coerceAtLeast(minBodyLong)
            .coerceAtMost(maxCardHeightPx)
            .toInt()
    } else {
        null
    }
    return ConfirmOverlayWindowLayout(
        width = width,
        height = WindowManager.LayoutParams.WRAP_CONTENT,
        gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL,
        yOffsetPx = bottomOffsetPx,
        flags = WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
        fitSystemBarsAndCutout = true,
        fitIme = false,
        maxBodyHeightPx = maxBodyHeightPx,
    )
}

/**
 * 统一安全门内部的确认悬浮窗（不暴露为 MCP 工具，harness §5.3 带内确认）。
 * 危险动作弹网关生成的卡片，人在手机上点头。
 *
 * **本类抛出的每一个错误都是 safety 终态**（`E_CONFIRM_TIMEOUT` / `E_PERM_MISSING` /
 * `E_CHANNEL_DOWN` / `E_BLOCKED`）：它们全都发生在危险工具**已经在调用中**，大脑必须按站规常规失败，
 * **不得输出 `[AWAIT_CONFIRM]`**。措辞集中在 [SafetyFallbacks]，由离线用例逐条钉住。
 */
object ConfirmOverlay {

    /** 供无障碍感知/动作面 fail-closed；只读，不提供任何机械确认入口。 */
    @Volatile
    var isAwaitingDecision: Boolean = false
        private set

    /** 默认确认超时（2026-11-16 对齐 backlog 决策为 90s）。 */
    internal const val DEFAULT_CONFIRM_TIMEOUT_MS: Long = 90_000L

    /** 锁屏/息屏状态兜底轮询间隔：广播负责瞬时响应，轮询兜底厂商延迟或非标准锁屏。 */
    private const val LOCK_STATE_POLL_INTERVAL_MS: Long = 200L

    /** 卡片底色；取证判据按它比对，改颜色必须两处一起改，故只留这一处定义。 */
    val CARD_BACKGROUND_COLOR: Int = Color.parseColor("#F2222222")

    private class MaxHeightScrollView(
        context: Context,
        private val maxHeightPx: Int,
    ) : ScrollView(context) {
        override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
            val cappedHeightSpec = if (maxHeightPx > 0) {
                val mode = MeasureSpec.getMode(heightMeasureSpec)
                val size = MeasureSpec.getSize(heightMeasureSpec)
                val bounded = if (mode == MeasureSpec.UNSPECIFIED) maxHeightPx else minOf(size, maxHeightPx)
                MeasureSpec.makeMeasureSpec(bounded, MeasureSpec.AT_MOST)
            } else {
                heightMeasureSpec
            }
            super.onMeasure(widthMeasureSpec, cappedHeightSpec)
        }
    }

    private class FrameFenceHandle(private val card: LinearLayout) {
        var preDrawListener: ViewTreeObserver.OnPreDrawListener? = null
        var drawListener: ViewTreeObserver.OnDrawListener? = null
        var frameCommitCallback: Runnable? = null
        var isDetached: Boolean = false
            private set

        fun detach() {
            isDetached = true
            val observer = card.viewTreeObserver
            val preDraw = preDrawListener
            preDrawListener = null
            if (preDraw != null && observer.isAlive) {
                runCatching { observer.removeOnPreDrawListener(preDraw) }
            }
            val listener = drawListener
            drawListener = null
            if (listener != null && observer.isAlive) {
                try {
                    observer.removeOnDrawListener(listener)
                } catch (_: IllegalStateException) {
                    // ViewTreeObserver 禁止在 onDraw 派发期同步移除监听；延迟到下一帧消息再摘除。
                    card.post {
                        val currentObserver = card.viewTreeObserver
                        if (currentObserver.isAlive) {
                            runCatching { currentObserver.removeOnDrawListener(listener) }
                        }
                    }
                }
            }
            val commit = frameCommitCallback
            frameCommitCallback = null
            if (commit != null && observer.isAlive) {
                runCatching { observer.unregisterFrameCommitCallback(commit) }
            }
        }
    }

    /** 阻塞调用方线程（工具线程，非主线程）直到 允许/拒绝/超时。 */
    @Synchronized
    fun ask(
        context: Context,
        actionDesc: String,
        overlayHost: ConfirmOverlayWindowHost? = null,
        timeoutMs: Long = DEFAULT_CONFIRM_TIMEOUT_MS,
        onShownBeforeButtonsEnabled: (ConfirmCardTarget?) -> Unit = {},
        /**
         * 观察到的真人决定 + 它来自哪条通道（无人决定时通道为 null）。
         * 通道只用于取证，**不参与任何放行判定**。
         */
        onDecisionObserved: (TestConfirmationDecision, ApprovalChannel?) -> Unit = { _, _ -> },
        /**
         * 与确认卡同时显示的通知证据面（批次 2）。通知只能拒绝或打开详情，批准能力只在
         * 已完成绘制与取证门的可见确认卡上。
         *
         * 卡片决定与通知拒绝共用下面那个 `future`：`CompletableFuture.complete` 只会成功一次，
         * 所以先到的有效决定赢，后到的一律被丢弃。
         */
        notification: ConfirmNotificationRequest? = null,
    ): Boolean {
        if (Looper.myLooper() == Looper.getMainLooper()) throw GatewayError(
            ErrorCode.E_CHANNEL_DOWN,
            "统一安全门不能在主线程等待确认",
            channel = "overlay",
            fallback = SafetyFallbacks.OVERLAY_CHANNEL_DOWN,
        )
        val windowKind = chooseConfirmOverlayWindowKind(
            accessibilityHostAvailable = overlayHost != null,
            canDrawOverlays = overlayHost == null && Settings.canDrawOverlays(context),
        )
        if (windowKind == ConfirmOverlayWindowKind.UNAVAILABLE) throw GatewayError(
            ErrorCode.E_PERM_MISSING, "悬浮窗权限未授予，带内确认不可用",
            channel = "overlay", fallback = SafetyFallbacks.OVERLAY_PERMISSION_MISSING,
        )
        val appContext = context.applicationContext ?: context
        val windowContext = if (windowKind == ConfirmOverlayWindowKind.ACCESSIBILITY_OVERLAY) {
            overlayHost!!.context
        } else {
            context
        }
        val windowType = if (windowKind == ConfirmOverlayWindowKind.ACCESSIBILITY_OVERLAY) {
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY
        } else {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        }

        val future = CompletableFuture<Boolean>()
        // 两条通道共用同一个 complete；这层只把"生效的那一次"归属到通道上，胜负判定一字未动。
        val approval = ApprovalChannelRecorder(future::complete)
        val cardShown = CompletableFuture<Unit>()
        // 卡片在屏幕上的真实位置与底色，取证时用来判断截图里到底有没有拍到卡本身。
        // 写在 cardShown.complete 之前、读在 cardShown.get 之后，两侧由 future 建立 happens-before。
        var cardTarget: ConfirmCardTarget? = null
        val buttonsEnabled = CompletableFuture<Unit>()
        val readiness = ConfirmationReadinessGate()
        val visibility = ConfirmOverlayVisibilityController()
        val main = Handler(Looper.getMainLooper())
        val wm = windowContext.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val keyguardManager = appContext.getSystemService(KeyguardManager::class.java)
        val powerManager = appContext.getSystemService(PowerManager::class.java)
        android.util.Log.i(
            "GatewayApproval",
            "confirm overlay host=${if (overlayHost != null) "accessibility" else "application"} type=$windowType",
        )
        isAwaitingDecision = true
        var attachedView: LinearLayout? = null
        var activeFence: FrameFenceHandle? = null
        val terminalError = AtomicReference<Throwable?>(null)
        var lockReceiverRegistered = false
        var lockMonitoringActive = false

        fun readDeviceState(broadcastAction: String? = null): ConfirmOverlayDeviceState =
            resolveConfirmOverlayDeviceState(
                isKeyguardLocked = keyguardManager?.isKeyguardLocked,
                isDeviceLocked = keyguardManager?.isDeviceLocked,
                isInteractive = powerManager?.isInteractive,
                broadcastAction = broadcastAction,
            )

        fun lockedBeforeShownError(): GatewayError = GatewayError(
            ErrorCode.E_BLOCKED,
            "设备处于锁屏或息屏状态，禁止在锁屏上展示确认卡",
            channel = "overlay",
            fallback = SafetyFallbacks.OVERLAY_LOCKED,
        )

        fun mappedFailure(operation: String, cause: Throwable): GatewayError {
            val root = (cause as? java.util.concurrent.ExecutionException)?.cause ?: cause
            if (root is GatewayError) return root
            val code = if (root is SecurityException) ErrorCode.E_PERM_MISSING else ErrorCode.E_CHANNEL_DOWN
            return GatewayError(
                code,
                "确认悬浮窗${operation}失败：${root.javaClass.simpleName}: ${root.message.orEmpty()}",
                channel = "overlay",
                fallback = if (code == ErrorCode.E_PERM_MISSING) {
                    SafetyFallbacks.OVERLAY_PERMISSION_MISSING
                } else {
                    SafetyFallbacks.OVERLAY_CHANNEL_DOWN
                },
            ).apply { initCause(root) }
        }

        fun setButtonsEnabled(group: LinearLayout, enabled: Boolean) {
            for (i in 0 until group.childCount) {
                when (val child = group.getChildAt(i)) {
                    is Button -> child.isEnabled = enabled
                    is LinearLayout -> setButtonsEnabled(child, enabled)
                }
            }
        }

        fun resolveWindowLayout(): ConfirmOverlayWindowLayout {
            val bounds = wm.currentWindowMetrics.bounds
            val density = windowContext.resources.displayMetrics.density
            return confirmOverlayWindowLayout(
                displayWidthPx = bounds.width(),
                displayHeightPx = bounds.height(),
                density = density,
            )
        }

        fun createLayoutParams(layout: ConfirmOverlayWindowLayout): WindowManager.LayoutParams {
            // NOT_FOCUSABLE 是必须的：可获焦的 overlay 会从 App 手里抢走窗口输入焦点，
            // 于是 ①App 窗口在卡显示期间既非 active 也非 focused，前台身份被判 unknown；
            // ②被操作 App 的 InputConnection 被拆掉重建，IME 会话 id 换新，确认后的
            // 焦点身份复核必判 stale——2026-07-26 真机两种症状先后各撞了一次。
            // 不可获焦的窗口照样收得到触摸事件，卡上的两个按钮不受影响。
            return WindowManager.LayoutParams(
                layout.width,
                layout.height,
                windowType,
                layout.flags,
                PixelFormat.TRANSLUCENT,
            ).apply {
                gravity = layout.gravity
                y = layout.yOffsetPx
                var insets = 0
                if (layout.fitSystemBarsAndCutout) {
                    insets = insets or WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout()
                }
                if (layout.fitIme) {
                    insets = insets or WindowInsets.Type.ime()
                }
                fitInsetsTypes = insets
            }
        }

        fun detachAttachedView(target: LinearLayout) {
            activeFence?.detach()
            activeFence = null
            setButtonsEnabled(target, false)
            target.visibility = View.GONE
            target.alpha = 0f
            try {
                wm.removeView(target)
                attachedView = null
            } catch (removeError: Throwable) {
                try {
                    // 已在主线程；立即移除作为普通 removeView 失败后的最后 fail-closed 清理。
                    wm.removeViewImmediate(target)
                    attachedView = null
                } catch (immediateError: Throwable) {
                    immediateError.addSuppressed(removeError)
                    throw immediateError
                }
            }
        }

        lateinit var lockReceiver: BroadcastReceiver
        lateinit var lockSyncRunnable: Runnable
        lateinit var syncLockState: (ConfirmOverlayDeviceState, Boolean) -> Unit

        fun stopLockMonitoring() {
            lockMonitoringActive = false
            main.removeCallbacks(lockSyncRunnable)
            if (lockReceiverRegistered) {
                lockReceiverRegistered = false
                runCatching { appContext.unregisterReceiver(lockReceiver) }
            }
        }

        fun failSessionOnMain(error: Throwable) {
            terminalError.compareAndSet(null, error)
            stopLockMonitoring()
            visibility.close()
            readiness.fail()
            attachedView?.let { target ->
                runCatching { detachAttachedView(target) }
            }
            cardShown.completeExceptionally(error)
            buttonsEnabled.completeExceptionally(error)
            future.completeExceptionally(error)
        }

        fun buildCardView(generation: Int, maxBodyHeightPx: Int?): LinearLayout = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(CARD_BACKGROUND_COLOR)
            setPadding(48, 40, 48, 40)

            addView(TextView(context).apply {
                text = "⚠ Agent 请求执行危险操作"
                setTextColor(Color.parseColor("#FFB74D"))
                textSize = 16f
            })
            val bodyView = TextView(context).apply {
                text = actionDesc
                setTextColor(Color.WHITE)
                textSize = 15f
                setPadding(0, 16, 0, 24)
            }
            if (maxBodyHeightPx != null && maxBodyHeightPx > 0) {
                addView(
                    MaxHeightScrollView(context, maxBodyHeightPx).apply {
                        isFillViewport = false
                        isVerticalScrollBarEnabled = true
                        addView(
                            bodyView,
                            ViewGroup.LayoutParams(
                                ViewGroup.LayoutParams.MATCH_PARENT,
                                ViewGroup.LayoutParams.WRAP_CONTENT,
                            ),
                        )
                    },
                    LinearLayout.LayoutParams(
                        LinearLayout.LayoutParams.MATCH_PARENT,
                        LinearLayout.LayoutParams.WRAP_CONTENT,
                    ),
                )
            } else {
                addView(bodyView)
            }
            addView(LinearLayout(context).apply {
                orientation = LinearLayout.HORIZONTAL
                addView(Button(context).apply {
                    text = "拒绝"
                    isEnabled = false
                    setOnClickListener {
                        val liveState = readDeviceState()
                        if (!visibility.canAcceptOverlayDecision(generation, liveState)) {
                            if (liveState.shouldHideOverlay) syncLockState(liveState, false)
                            return@setOnClickListener
                        }
                        approval.decide(ApprovalChannel.OVERLAY, false)
                    }
                }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
                addView(Button(context).apply {
                    text = "允许本次"
                    isEnabled = false
                    setOnClickListener {
                        val liveState = readDeviceState()
                        if (!visibility.canAcceptOverlayDecision(generation, liveState)) {
                            if (liveState.shouldHideOverlay) syncLockState(liveState, false)
                            return@setOnClickListener
                        }
                        approval.decide(ApprovalChannel.OVERLAY, true)
                    }
                }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
            })
        }

        fun attachCard(generation: Int, initial: Boolean) {
            val layout = resolveWindowLayout()
            val card = buildCardView(generation, layout.maxBodyHeightPx)
            val fence = FrameFenceHandle(card)
            val lp = createLayoutParams(layout)
            try {
                if (initial) {
                    fun completeCommittedFrame(fromOnDraw: Boolean) {
                        if (readiness.state() != ConfirmationReadinessGate.State.FRAME_COMMITTED) return
                        val liveState = readDeviceState()
                        if (liveState.shouldHideOverlay) {
                            if (fromOnDraw) {
                                main.post { syncLockState(liveState, false) }
                            } else {
                                syncLockState(liveState, false)
                            }
                            return
                        }
                        if (!visibility.onInitialFrameCommitted(generation)) return
                        val origin = IntArray(2).also(card::getLocationOnScreen)
                        cardTarget = ConfirmCardTarget(
                            left = origin[0],
                            top = origin[1],
                            right = origin[0] + card.width,
                            bottom = origin[1] + card.height,
                            backgroundColor = CARD_BACKGROUND_COLOR,
                        )
                        if (cardShown.complete(Unit)) {
                            card.post { fence.detach() }
                        }
                    }
                    val beforeDraw = object : ViewTreeObserver.OnPreDrawListener {
                        override fun onPreDraw(): Boolean {
                            if (!readiness.registerFrameCommit()) return true
                            if (!card.isHardwareAccelerated) {
                                fence.detach()
                                failSessionOnMain(
                                    IllegalStateException("确认卡窗口未启用硬件加速，无法建立 frame commit fence"),
                                )
                                return true
                            }
                            val observer = card.viewTreeObserver
                            if (!observer.isAlive) {
                                fence.detach()
                                failSessionOnMain(IllegalStateException("确认卡 ViewTreeObserver 已失效"))
                                return true
                            }
                            try {
                                val committed = Runnable {
                                    try {
                                        fence.frameCommitCallback = null
                                        if (visibility.currentGeneration() != generation) return@Runnable
                                        readiness.frameCommitted()
                                        completeCommittedFrame(fromOnDraw = false)
                                    } catch (error: Throwable) {
                                        fence.detach()
                                        failSessionOnMain(error)
                                    }
                                }
                                fence.frameCommitCallback = committed
                                observer.registerFrameCommitCallback(committed)
                                observer.removeOnPreDrawListener(this)
                                fence.preDrawListener = null
                            } catch (error: Throwable) {
                                fence.detach()
                                failSessionOnMain(error)
                            }
                            return true
                        }
                    }
                    val listener = object : ViewTreeObserver.OnDrawListener {
                        override fun onDraw() {
                            if (fence.isDetached || visibility.currentGeneration() != generation) return
                            readiness.observeDraw()
                            completeCommittedFrame(fromOnDraw = true)
                        }
                    }
                    fence.preDrawListener = beforeDraw
                    fence.drawListener = listener
                    card.viewTreeObserver.addOnPreDrawListener(beforeDraw)
                    card.viewTreeObserver.addOnDrawListener(listener)
                } else {
                    fun finishReattachEnable(targetGeneration: Int) {
                        if (attachedView !== card || visibility.currentGeneration() != targetGeneration) return
                        val liveState = readDeviceState()
                        if (liveState.shouldHideOverlay) {
                            syncLockState(liveState, false)
                            return
                        }
                        if (!visibility.canAcceptOverlayDecision(targetGeneration, liveState)) return
                        setButtonsEnabled(card, true)
                        if (activeFence === fence) activeFence = null
                        fence.detach()
                    }
                    fun applyReattachAction(
                        action: ConfirmOverlayVisibilityController.Action,
                        fromOnDraw: Boolean,
                    ) {
                        if (action !is ConfirmOverlayVisibilityController.Action.EnableButtons) return
                        if (fromOnDraw) {
                            // 避开在 onDraw 派发期修改按钮/摘除监听或卸载窗口。
                            main.post { finishReattachEnable(action.generation) }
                        } else {
                            finishReattachEnable(action.generation)
                        }
                    }
                    val beforeDraw = object : ViewTreeObserver.OnPreDrawListener {
                        override fun onPreDraw(): Boolean {
                            if (!visibility.registerReattachFrameCommit(generation)) return true
                            if (!card.isHardwareAccelerated) {
                                fence.detach()
                                failSessionOnMain(
                                    IllegalStateException("确认卡解锁恢复窗口未启用硬件加速，无法建立 frame commit fence"),
                                )
                                return true
                            }
                            val observer = card.viewTreeObserver
                            if (!observer.isAlive) {
                                fence.detach()
                                failSessionOnMain(IllegalStateException("确认卡解锁恢复 ViewTreeObserver 已失效"))
                                return true
                            }
                            try {
                                val committed = Runnable {
                                    try {
                                        fence.frameCommitCallback = null
                                        if (visibility.currentGeneration() != generation) return@Runnable
                                        val liveState = readDeviceState()
                                        if (liveState.shouldHideOverlay) {
                                            syncLockState(liveState, false)
                                            return@Runnable
                                        }
                                        applyReattachAction(
                                            visibility.observeReattachFrameCommitted(generation),
                                            fromOnDraw = false,
                                        )
                                    } catch (error: Throwable) {
                                        fence.detach()
                                        failSessionOnMain(error)
                                    }
                                }
                                fence.frameCommitCallback = committed
                                observer.registerFrameCommitCallback(committed)
                                observer.removeOnPreDrawListener(this)
                                fence.preDrawListener = null
                            } catch (error: Throwable) {
                                fence.detach()
                                failSessionOnMain(error)
                            }
                            return true
                        }
                    }
                    val listener = object : ViewTreeObserver.OnDrawListener {
                        override fun onDraw() {
                            if (fence.isDetached || visibility.currentGeneration() != generation) return
                            applyReattachAction(
                                visibility.observeReattachDraw(generation),
                                fromOnDraw = true,
                            )
                        }
                    }
                    fence.preDrawListener = beforeDraw
                    fence.drawListener = listener
                    card.viewTreeObserver.addOnPreDrawListener(beforeDraw)
                    card.viewTreeObserver.addOnDrawListener(listener)
                }
                wm.addView(card, lp)
                attachedView = card
                activeFence = fence
            } catch (error: Throwable) {
                fence.detach()
                throw error
            }
        }

        syncLockState = { deviceState, allowReattach ->
            when (val action = visibility.onDeviceStateChanged(deviceState, allowReattach = allowReattach)) {
                ConfirmOverlayVisibilityController.Action.NoOp,
                is ConfirmOverlayVisibilityController.Action.AttachInitial,
                is ConfirmOverlayVisibilityController.Action.EnableButtons,
                -> Unit
                ConfirmOverlayVisibilityController.Action.FailLockedBeforeShown -> {
                    android.util.Log.i("GatewayApproval", "confirm overlay blocked: device locked before attach")
                    failSessionOnMain(lockedBeforeShownError())
                }
                is ConfirmOverlayVisibilityController.Action.DetachAndFailLocked -> {
                    android.util.Log.i("GatewayApproval", "confirm overlay aborted: device locked before frame commit")
                    failSessionOnMain(lockedBeforeShownError())
                }
                is ConfirmOverlayVisibilityController.Action.DetachForLock -> {
                    val target = attachedView
                    if (target != null) {
                        try {
                            detachAttachedView(target)
                            android.util.Log.i("GatewayApproval", "confirm overlay hidden for lockscreen")
                        } catch (error: Throwable) {
                            failSessionOnMain(error)
                        }
                    }
                }
                is ConfirmOverlayVisibilityController.Action.ReattachAfterUnlock -> {
                    try {
                        attachCard(action.generation, initial = false)
                        android.util.Log.i("GatewayApproval", "confirm overlay restored after unlock")
                    } catch (error: Throwable) {
                        failSessionOnMain(error)
                    }
                }
            }
        }

        lockReceiver = object : BroadcastReceiver() {
            override fun onReceive(receiverContext: Context?, intent: Intent?) {
                if (!lockMonitoringActive || visibility.phase() == ConfirmOverlayVisibilityController.Phase.CLOSED) {
                    return
                }
                val action = intent?.action
                if (!isConfirmOverlayLockBroadcastAction(action)) return
                syncLockState(
                    readDeviceState(broadcastAction = action),
                    shouldAllowOverlayReattachOnBroadcast(action),
                )
            }
        }

        lockSyncRunnable = object : Runnable {
            override fun run() {
                if (!lockMonitoringActive || visibility.phase() == ConfirmOverlayVisibilityController.Phase.CLOSED) {
                    return
                }
                syncLockState(readDeviceState(), true)
                if (lockMonitoringActive && visibility.phase() != ConfirmOverlayVisibilityController.Phase.CLOSED) {
                    main.postDelayed(this, LOCK_STATE_POLL_INTERVAL_MS)
                }
            }
        }

        fun startLockMonitoring() {
            val filter = IntentFilter().apply {
                CONFIRM_OVERLAY_LOCK_BROADCAST_ACTIONS.forEach(::addAction)
            }
            ContextCompat.registerReceiver(
                appContext,
                lockReceiver,
                filter,
                CONFIRM_OVERLAY_LOCK_RECEIVER_FLAGS,
            )
            lockReceiverRegistered = true
            lockMonitoringActive = true
            main.postDelayed(lockSyncRunnable, LOCK_STATE_POLL_INTERVAL_MS)
        }

        fun dismissBlocking(): GatewayError? {
            val dismissed = CompletableFuture<Unit>()
            // 即使此刻 view 仍为空也必须排队：同一 main Handler 的 FIFO 保证 pending show 先执行，
            // cleanup 随后移除它，避免等待超时后迟到显示一张孤儿确认卡。
            val posted = main.post {
                stopLockMonitoring()
                visibility.close()
                val target = attachedView
                if (target == null) {
                    activeFence?.detach()
                    activeFence = null
                    readiness.fail()
                    isAwaitingDecision = false
                    dismissed.complete(Unit)
                } else try {
                    readiness.fail()
                    detachAttachedView(target)
                    isAwaitingDecision = false
                    dismissed.complete(Unit)
                } catch (error: Throwable) {
                    // 保留 attachedView 引用，明确表示清理未成功；调用方会收到结构化失败且不得执行动作。
                    dismissed.completeExceptionally(error)
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
                startLockMonitoring()
                when (val action = visibility.beginInitialAttach(readDeviceState())) {
                    is ConfirmOverlayVisibilityController.Action.AttachInitial -> {
                        attachCard(action.generation, initial = true)
                    }
                    ConfirmOverlayVisibilityController.Action.FailLockedBeforeShown -> {
                        android.util.Log.i("GatewayApproval", "confirm overlay blocked: device locked before attach")
                        failSessionOnMain(lockedBeforeShownError())
                    }
                    else -> Unit
                }
            } catch (error: Throwable) {
                failSessionOnMain(error)
            }
        }
        if (!posted) {
            val error = IllegalStateException("主线程 Handler 已停止")
            cardShown.completeExceptionally(error)
            buttonsEnabled.completeExceptionally(error)
            future.completeExceptionally(error)
        }

        var result: Boolean? = null
        var failure: GatewayError? = null
        var waitingForHuman = false
        /** 已在裁决点登记的确认编号；收摊时只关自己这一次，不误关别人后开的。 */
        var notificationOpened: String? = null
        try {
            cardShown.get(2, TimeUnit.SECONDS)
            terminalError.get()?.let { throw it }
            try {
                readiness.beginEvidence()
            } catch (error: IllegalStateException) {
                terminalError.get()?.let { throw it }
                throw error
            }
            // 可选的附加证据在首帧 draw fence 后同步准备；失败时按钮从未启用。
            onShownBeforeButtonsEnabled(cardTarget)
            terminalError.get()?.let { throw it }
            try {
                readiness.evidenceReady()
            } catch (error: IllegalStateException) {
                terminalError.get()?.let { throw it }
                throw error
            }
            val enablePosted = main.post {
                syncLockState(readDeviceState(), true)
                if (visibility.phase() != ConfirmOverlayVisibilityController.Phase.EVIDENCE_PENDING) {
                    val reason = terminalError.get() ?: if (visibility.isLocked()) {
                        lockedBeforeShownError()
                    } else {
                        IllegalStateException("确认卡已不存在")
                    }
                    buttonsEnabled.completeExceptionally(reason)
                } else {
                    try {
                        readiness.enableButtons()
                        when (val action = visibility.onEvidenceReady()) {
                            is ConfirmOverlayVisibilityController.Action.EnableButtons -> {
                                val card = attachedView
                                if (card != null && visibility.currentGeneration() == action.generation) {
                                    setButtonsEnabled(card, true)
                                    val fence = activeFence
                                    if (fence != null) {
                                        activeFence = null
                                        card.post { fence.detach() }
                                    }
                                }
                            }
                            else -> Unit
                        }
                        buttonsEnabled.complete(Unit)
                    } catch (error: Throwable) {
                        readiness.fail()
                        buttonsEnabled.completeExceptionally(error)
                    }
                }
            }
            if (!enablePosted) throw IllegalStateException("主线程 Handler 已停止")
            buttonsEnabled.get(2, TimeUnit.SECONDS)
            // 通知在**卡的按钮已经可点之后**才推：即便通知只有拒绝能力，也不能让本轮证据面
            // 先于确认卡完成绘制与取证，避免用户看到尚未就绪的确认状态。
            notification?.let { request ->
                ConfirmApprovalArbiter.open(request.confirmationId, request.nonce) { allowed ->
                    approval.decide(ApprovalChannel.NOTIFICATION, allowed)
                }
                notificationOpened = request.confirmationId
                runCatching {
                    ConfirmNotifier.post(
                        context = context,
                        confirmationId = request.confirmationId,
                        nonce = request.nonce,
                        tier = request.riskTier,
                        action = request.action,
                        target = request.target,
                        targetPackage = request.targetPackage,
                        preview = request.preview,
                        // 通知的存活时长跟着确认窗口走（见 ConfirmNotifier 的 setTimeoutAfter）：
                        // 「可见」靠不做 ongoing，「持久」靠超时，两件事分开解决。
                        timeoutMs = timeoutMs,
                    )
                }.onFailure { error ->
                    // 推不出通知不该让整条链失败：悬浮卡仍然在屏幕上，人照样能点。
                    // 但必须留痕，否则"通知拒绝/证据提醒不可用"会被当成用户没看见。
                    android.util.Log.w("GatewayApproval", "审批通知推送失败，仅保留悬浮卡：$error")
                }
            }
            waitingForHuman = true
            result = future.get(timeoutMs, TimeUnit.MILLISECONDS)
        } catch (e: java.util.concurrent.TimeoutException) {
            failure = if (waitingForHuman) {
                GatewayError(
                    ErrorCode.E_CONFIRM_TIMEOUT, "带内确认 ${timeoutMs / 1000}s 无人响应",
                    channel = "overlay",
                    // 原文引着 harness spec §5.1 却写了与它相反的指令。§5.1 本身没错，
                    // 它写的是：gateway 只在**尚未调用危险工具**时才可输出 [AWAIT_CONFIRM]，
                    // 一旦危险工具已返回超时/拒绝/stale/blocked/缺权限，本腿必须常规失败。
                    // 引用一份说着相反话的 spec，会让错误的指令看起来是被授权的。
                    fallback = SafetyFallbacks.CONFIRM_TIMEOUT,
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

        // 收摊顺序：先关审批窗口再撤通知。反过来的话，通知已经没了、裁决点还开着，
        // 一条迟到的回执仍能落到这次确认上。
        notificationOpened?.let { id ->
            ConfirmApprovalArbiter.close(id)
            runCatching { ConfirmNotifier.cancel(context) }
        }

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
                onDecisionObserved(decision, approval.winner())
            } catch (error: Throwable) {
                throw if (error is GatewayError) error else mappedFailure("记录确认状态", error)
            }
        }
        failure?.let { throw it }
        return result ?: throw mappedFailure("等待", IllegalStateException("确认结果为空"))
    }
}
