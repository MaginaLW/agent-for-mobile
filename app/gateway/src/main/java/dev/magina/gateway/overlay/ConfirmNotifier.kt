package dev.magina.gateway.overlay

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import dev.magina.gateway.core.ConfirmNotificationContent
import dev.magina.gateway.core.RiskTier

/**
 * 危险动作审批通知（批次 2）。与 [ConfirmOverlay] 的悬浮卡**并联**：同一次确认两条通道，
 * 谁先点谁算数，由 `ConfirmApprovalArbiter` 裁决。
 *
 * 三条按 B 道拍板落地的形态，改之前先看理由：
 *
 * - **不声明 `USE_FULL_SCREEN_INTENT`**（决定二）。FSI 的作用正是把整页免解锁糊到锁屏上，
 *   而 L1 已经决定用 `VISIBILITY_PRIVATE` 把明文挡在锁屏外，两者直接冲突。不声明也顺带省掉
 *   一条需要用户去系统设置手动打开的依赖。通知停在展开态，点进去才看全部证据。
 * - **独立的 `IMPORTANCE_HIGH` 通道**，与前台服务那条 `IMPORTANCE_LOW` 分开：混在一起时
 *   用户嫌吵关掉整个通道，会连审批一起关掉而不自知。
 * - **`setAuthenticationRequired` 保持默认 false**：见 [allowAction] 上的说明，
 *   那是用户的明示选择，不是漏设的默认值。
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
            "危险操作审批",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "Agent 请求执行危险操作时推送，可直接在锁屏上批准或拒绝"
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
    ) {
        ensureChannel(context)
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        val publicLine = ConfirmNotificationContent.publicLine(tier, action, target)

        // 锁屏上真正显示的那一份：只有"档位 · 动作 → 目标"，一个字的明文都没有。
        // 免解锁批准（决定三）时用户读到的就是这一行——B 道拍板 §2.1 已把这条记为预期形态。
        val publicVersion = Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_alert)
            .setContentTitle(ConfirmNotificationContent.TITLE)
            .setContentText(publicLine)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .build()

        val notification = Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_alert)
            .setContentTitle(ConfirmNotificationContent.TITLE)
            .setContentText(publicLine)
            .setStyle(
                Notification.BigTextStyle().bigText(
                    ConfirmNotificationContent.expandedText(tier, target, preview)
                )
            )
            .setCategory(Notification.CATEGORY_CALL)
            .setOngoing(true)
            .setAutoCancel(false)
            // 通知本体只放脱敏版本上锁屏；完整三项锚点要解锁展开才看得到。
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setPublicVersion(publicVersion)
            .addAction(allowAction(context, confirmationId, nonce))
            .addAction(denyAction(context, confirmationId, nonce))
            .addAction(detailsAction(context))
            .build()
        manager.notify(NOTIFICATION_ID, notification)
    }

    fun cancel(context: Context) {
        context.getSystemService(NotificationManager::class.java)?.cancel(NOTIFICATION_ID)
    }

    /**
     * 「允许本次」。
     *
     * **`setAuthenticationRequired(true)` 是有意没有加的**——这是用户 2026-08-01 经
     * AskUserQuestion 作出的**明示选择**（B 道拍板 `2026-08-01-通知栏审批布局-B道拍板.md` §2），
     * 不是遗漏的默认值，**请不要"顺手修掉"**。
     *
     * 被接受的风险，如实写在这里：**任何拿到这台手机的人，都能在 60 秒确认窗口内替用户批准
     * 一笔转账、一次删除、一次改密码，不需要锁屏密码。** 批次 2 的红线（审批通道让大脑碰不到）
     * 挡的是大脑，挡不到物理接触。
     *
     * 换来的是批次 2 的收益完整兑现：任何危险动作都是锁屏上一次点击。
     *
     * **重开条件**（任一命中就重新走 B 道）：手机曾离开用户控制（丢失、借出、被他人长时间持有），
     * 或出现一次真实的误批准。届时最小改动就是在这里按 `riskTier` 给 I 级挂上
     * `setAuthenticationRequired(true)`——接口就在手边，改动量很小，所以现在选宽松没有把路堵死。
     */
    private fun allowAction(context: Context, confirmationId: String, nonce: String): Notification.Action =
        Notification.Action.Builder(
            null,
            "允许本次",
            decisionIntent(context, confirmationId, nonce, allowed = true),
        ).build()

    private fun denyAction(context: Context, confirmationId: String, nonce: String): Notification.Action =
        Notification.Action.Builder(
            null,
            "拒绝",
            decisionIntent(context, confirmationId, nonce, allowed = false),
        ).build()

    /** 第三个按钮：解锁并回到设备，完整 8 项证据在已经显示着的确认卡上。 */
    private fun detailsAction(context: Context): Notification.Action {
        val open = Intent(Intent.ACTION_MAIN)
            .setClassName(context.packageName, "${context.packageName}.MainActivity")
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return Notification.Action.Builder(
            null,
            "查看全部证据",
            PendingIntent.getActivity(
                context,
                REQUEST_DETAILS,
                open,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            ),
        ).build()
    }

    /**
     * 回执 PendingIntent。三处刻意的写法：
     *
     * - **显式组件 + 限定本包**：广播只可能落到自家不导出的 receiver 上。
     * - **`FLAG_IMMUTABLE`**：拿到这个 PendingIntent 的人改不了里面的 extras，
     *   也就伪造不出"另一个 confirmationId / 另一个 allowed"。
     * - **`FLAG_UPDATE_CURRENT` + 按 allowed 分开的 requestCode**：允许与拒绝是两个不同的
     *   PendingIntent，不会互相覆盖；而同一次确认重复 post 时更新的是同一个，nonce 保持一致。
     */
    private fun decisionIntent(
        context: Context,
        confirmationId: String,
        nonce: String,
        allowed: Boolean,
    ): PendingIntent {
        val intent = Intent(ACTION_DECIDE)
            .setClassName(context.packageName, ConfirmDecisionReceiver::class.java.name)
            .setPackage(context.packageName)
            .putExtra(EXTRA_CONFIRMATION_ID, confirmationId)
            .putExtra(EXTRA_NONCE, nonce)
            .putExtra(EXTRA_ALLOWED, allowed)
        return PendingIntent.getBroadcast(
            context,
            if (allowed) REQUEST_ALLOW else REQUEST_DENY,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private const val REQUEST_ALLOW = 0x9101
    private const val REQUEST_DENY = 0x9102
    private const val REQUEST_DETAILS = 0x9103
}
