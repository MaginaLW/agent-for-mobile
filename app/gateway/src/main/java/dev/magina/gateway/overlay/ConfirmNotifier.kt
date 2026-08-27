package dev.magina.gateway.overlay

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import dev.magina.gateway.core.ConfirmNotificationContent
import dev.magina.gateway.core.RiskTier

/**
 * 通知允许暴露的操作面。这里刻意没有 `ALLOW`：通知监听器能够代发通知 action 的
 * `PendingIntent`，所以批准能力只能留在已经绘制并启用的 [ConfirmOverlay] 按钮上。
 */
internal enum class ConfirmNotificationAction {
    DENY,
    DETAILS,
}

internal fun confirmNotificationActions(): List<ConfirmNotificationAction> = listOf(
    ConfirmNotificationAction.DENY,
    ConfirmNotificationAction.DETAILS,
)

/** Android `PendingIntent` 的身份与生命周期策略；纯函数产出，供 JVM 用例钉住。 */
internal data class ConfirmNotificationPendingIntentSpec(
    val requestCode: Int,
    val dataUri: String,
    val flags: Int,
)

internal fun confirmNotificationPendingIntentSpec(
    confirmationId: String,
    action: ConfirmNotificationAction,
): ConfirmNotificationPendingIntentSpec {
    val actionName = when (action) {
        ConfirmNotificationAction.DENY -> "deny"
        ConfirmNotificationAction.DETAILS -> "details"
    }
    return ConfirmNotificationPendingIntentSpec(
        requestCode = when (action) {
            ConfirmNotificationAction.DENY -> REQUEST_DENY
            ConfirmNotificationAction.DETAILS -> REQUEST_DETAILS
        },
        // extras 不参与 PendingIntent 匹配；完整 confirmationId 必须进入 data 才能隔离两次确认。
        dataUri = "gateway-confirmation://notification/$actionName/${confirmationId.encodeAsHex()}",
        flags = PendingIntent.FLAG_CANCEL_CURRENT or
            PendingIntent.FLAG_IMMUTABLE or
            PendingIntent.FLAG_ONE_SHOT,
    )
}

private fun String.encodeAsHex(): String = buildString(length * 4) {
    this@encodeAsHex.forEach { character ->
        val value = character.code
        append(HEX_DIGITS[(value ushr 12) and 0x0f])
        append(HEX_DIGITS[(value ushr 8) and 0x0f])
        append(HEX_DIGITS[(value ushr 4) and 0x0f])
        append(HEX_DIGITS[value and 0x0f])
    }
}

/**
 * 危险动作证据通知（批次 2）。它与 [ConfirmOverlay] 同时显示，但能力不对称：通知只允许
 * **拒绝**或回到 App 查看证据，批准只能在已经完成绘制与取证门的可见悬浮卡上完成。
 *
 * 两条沿用的通知形态，改之前先看理由：
 *
 * - **不声明 `USE_FULL_SCREEN_INTENT`**（决定二）。FSI 的作用正是把整页免解锁糊到锁屏上，
 *   而 L1 已经决定用 `VISIBILITY_PRIVATE` 把明文挡在锁屏外，两者直接冲突。不声明也顺带省掉
 *   一条需要用户去系统设置手动打开的依赖。通知停在展开态，点进去才看全部证据。
 * - **独立的 `IMPORTANCE_HIGH` 通道**，与前台服务那条 `IMPORTANCE_LOW` 分开：混在一起时
 *   用户嫌吵关掉整个通道，会连审批一起关掉而不自知。
 * **本类的实际适用面（2026-08-02 收窄）**：批次 2 现在验的是「屏幕亮着但人没盯着」——
 * heads-up 浮窗或下拉通知栏里能看到脱敏证据并及时拒绝。通知上的 action PendingIntent
 * 可能被 NotificationListener 代发，因此绝不能携带批准能力。
 */
object ConfirmNotifier {

    const val CHANNEL_ID: String = "gateway-approval"
    const val NOTIFICATION_ID: Int = 0x9001

    const val ACTION_DECIDE: String = "dev.magina.gateway.APPROVAL_DECISION"
    const val EXTRA_CONFIRMATION_ID: String = "confirmation_id"
    const val EXTRA_NONCE: String = "nonce"
    const val EXTRA_ALLOWED: String = "allowed"

    fun ensureChannel(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "危险操作确认提醒",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "Agent 请求执行危险操作时推送；可拒绝或查看证据，批准仅限屏幕确认卡"
            setShowBadge(true)
            lockscreenVisibility = Notification.VISIBILITY_PRIVATE
        }
        manager.createNotificationChannel(channel)
    }

    /**
     * 推一条审批通知。[nonce] 只进 PendingIntent 的 extras，**不进任何面向大脑的返回体**。
     *
     * @param preview 明文预览；只出现在需要解锁才能看到的展开态，绝不进 public version。
     */
    fun post(
        context: Context,
        confirmationId: String,
        nonce: String,
        tier: RiskTier,
        action: String,
        target: String,
        targetPackage: String,
        preview: String?,
        timeoutMs: Long,
    ) {
        ensureChannel(context)
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        val publicLine = ConfirmNotificationContent.publicLine(tier, action, target)

        // 锁屏上真正显示的那一份：只有"档位 · 动作 → 目标"，一个字的明文都没有。
        // 锁屏上只能看到这一行脱敏证据；通知不提供批准入口。
        val publicVersion = Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_alert)
            .setContentTitle(ConfirmNotificationContent.TITLE)
            .setContentText(publicLine)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .build()

        val builder = Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_alert)
            .setContentTitle(ConfirmNotificationContent.TITLE)
            .setContentText(publicLine)
            .setStyle(
                Notification.BigTextStyle().bigText(
                    ConfirmNotificationContent.expandedText(tier, target, preview)
                )
            )
            // **刻意不设 CATEGORY_CALL。** 2026-08-02 第三次验收：锁屏渲染本身是好的
            // （同一时刻另一条 app 通知正常显示、zen_mode=0），唯独网关这条不在——
            // 而 CATEGORY_CALL 是我们与那条通知最显眼的差异之一。
            //
            // 它本来也是错的：这不是通话。Android 14+ 要求通话类通知用 `Notification.CallStyle`，
            // 非 CallStyle 的 CATEGORY_CALL 属于不合规形态，系统有权按自己的规则降级处理。
            // **用一个语义不符的 category 去换排序权重，迟早在别处咬回来**——现在就咬了。
            //
            // 紧急度本来就由通道的 IMPORTANCE_HIGH 提供，去掉它不损失任何我们依赖的东西。
            // 本轮**只动这一个变量**：autogroup 那条候选留给下一轮的差集数据来判。
            // **刻意不调 setOngoing(true)。** 2026-08-01 批次 2 真机验收：用户锁屏后根本看不到
            // 这条通知，两次 timed_out；系统与厂商的每 App 锁屏开关都是开的、通道 importance=4、
            // 通知确实 posted 且带 publicVersion、fullscreenIntent=null。
            // 同机旁证很硬：本包那条**常驻的前台服务通知（ongoing）同样不上锁屏**。
            // ongoing 通知带 FLAG_ONGOING_EVENT，锁屏通知列表历来把它过滤掉——而批次 2 的
            // 全部收益就是"锁屏上点一下"，为了防误划走而牺牲掉整个功能是本末倒置。
            //
            // 代价是用户可以把它划掉。**划掉不是决定**：悬浮卡还在屏幕上，60 秒超时照旧，
            // 绝不会因为一次误划而产生 allowed/denied。所以这里也没有 setDeleteIntent——
            // 给"划走"接一个回执，等于给它安一个决定的语义。
            .setAutoCancel(false)
            // 「可见」与「持久」是两件事，上一轮把它们混在一个 setOngoing 里解决，结果是通知
            // 上了锁屏黑名单。2026-08-02 真机：去掉 ongoing 后 flags=0、锁屏能显示了，
            // 但通知**随卡出现、随即消失**——ongoing 顺带给的 FLAG_NO_CLEAR 粘性也一并没了。
            //
            // 用超时而不是 ongoing 来维持存在：确认窗口多长，它就活多长，到点由系统自己收走。
            // 这样既不进锁屏黑名单，也不会在确认结束后留下一条僵尸通知。
            // 多给一点余量，免得系统先于确认窗口把它收走；正常路径上收摊时会主动 cancel。
            .setTimeoutAfter(timeoutMs + TIMEOUT_SLACK_MS)
            // 通知本体只放脱敏版本上锁屏；完整三项锚点要解锁展开才看得到。
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setPublicVersion(publicVersion)
        confirmNotificationActions().forEach { notificationAction ->
            builder.addAction(
                when (notificationAction) {
                    ConfirmNotificationAction.DENY -> denyAction(context, confirmationId, nonce)
                    ConfirmNotificationAction.DETAILS -> detailsAction(context, confirmationId)
                }
            )
        }
        manager.notify(NOTIFICATION_ID, builder.build())
    }

    fun cancel(context: Context) {
        context.getSystemService(NotificationManager::class.java)?.cancel(NOTIFICATION_ID)
    }

    private fun denyAction(context: Context, confirmationId: String, nonce: String): Notification.Action =
        Notification.Action.Builder(
            null,
            "拒绝",
            denyIntent(context, confirmationId, nonce),
        ).build()

    /** 第二个按钮：解锁并回到设备，完整 8 项证据在已经显示着的确认卡上。 */
    private fun detailsAction(context: Context, confirmationId: String): Notification.Action {
        val spec = confirmNotificationPendingIntentSpec(
            confirmationId,
            ConfirmNotificationAction.DETAILS,
        )
        val open = Intent(Intent.ACTION_MAIN)
            .setClassName(context.packageName, "${context.packageName}.MainActivity")
            .setData(Uri.parse(spec.dataUri))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return Notification.Action.Builder(
            null,
            "查看全部证据",
            PendingIntent.getActivity(
                context,
                spec.requestCode,
                open,
                spec.flags,
            ),
        ).build()
    }

    /**
     * 「拒绝」回执 PendingIntent。批准没有对应 builder，能力只存在于可见确认卡。
     *
     * - **显式组件 + 限定本包**：广播只可能落到自家不导出的 receiver 上。
     * - **`FLAG_IMMUTABLE`**：拿到这个 PendingIntent 的人改不了里面的 extras，
     *   也就伪造不出另一个 confirmationId / nonce。
     * - **唯一 data URI**：confirmationId 是 Android 匹配身份的一部分，A 的句柄不会被 B 更新。
     * - **`FLAG_CANCEL_CURRENT | FLAG_ONE_SHOT`**：同一次确认重复 post 时旧句柄先失效，
     *   新句柄成功发送一次后也立即失效；绝不使用会改写旧句柄 extras 的 UPDATE_CURRENT。
     */
    internal fun denyIntent(
        context: Context,
        confirmationId: String,
        nonce: String,
    ): PendingIntent {
        val spec = confirmNotificationPendingIntentSpec(
            confirmationId,
            ConfirmNotificationAction.DENY,
        )
        val intent = Intent(ACTION_DECIDE)
            .setClassName(context.packageName, ConfirmDecisionReceiver::class.java.name)
            .setPackage(context.packageName)
            .setData(Uri.parse(spec.dataUri))
            .putExtra(EXTRA_CONFIRMATION_ID, confirmationId)
            .putExtra(EXTRA_NONCE, nonce)
            .putExtra(EXTRA_ALLOWED, false)
        return PendingIntent.getBroadcast(
            context,
            spec.requestCode,
            intent,
            spec.flags,
        )
    }

    /** 确认窗口之外再多给 15s：宁可晚一点被系统收走，不可早于人还能点的时候就消失。 */
    private const val TIMEOUT_SLACK_MS = 15_000L

}

private const val HEX_DIGITS = "0123456789abcdef"
private const val REQUEST_DENY = 0x9102
private const val REQUEST_DETAILS = 0x9103
