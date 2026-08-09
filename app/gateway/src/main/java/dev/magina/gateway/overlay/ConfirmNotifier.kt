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
 * 决策广播的 Android `PendingIntent` 身份与生命周期策略。纯函数产出，供 JVM 用例钉住；
 * [ConfirmNotifier.decisionIntent] 必须直接消费这份结果，不能另造一套 identity。
 */
internal data class DecisionPendingIntentSpec(
    val requestCode: Int,
    val dataUri: String,
    val flags: Int,
)

internal fun decisionPendingIntentSpec(
    confirmationId: String,
    allowed: Boolean,
): DecisionPendingIntentSpec {
    val decision = if (allowed) "allow" else "deny"
    return DecisionPendingIntentSpec(
        requestCode = if (allowed) REQUEST_ALLOW else REQUEST_DENY,
        // extras 不参与 PendingIntent 匹配；把完整 confirmationId 无碰撞编码进 data 才是身份。
        dataUri = "gateway-approval://decision/$decision/${confirmationId.encodeAsHex()}",
        flags = PendingIntent.FLAG_CANCEL_CURRENT or
            PendingIntent.FLAG_IMMUTABLE or
            PendingIntent.FLAG_ONE_SHOT,
    )
}

/**
 * 通知本身不会在点击后自动消失，详情入口也必须保持可重复点击；它不承载可变 extras，
 * 因而只需不可变语义，不能使用 one-shot、update 或 cancel-current。
 */
internal fun detailsPendingIntentFlags(): Int = PendingIntent.FLAG_IMMUTABLE

/**
 * 生产实际使用的审批回执 Intent builder。JVM 契约测试通过 Robolectric 直接执行这段 Android
 * 组装代码，避免只测一份平行 spec、而真实 Intent 漏掉 component/data/extras 仍然绿。
 */
internal fun buildDecisionIntent(
    context: Context,
    confirmationId: String,
    nonce: String,
    allowed: Boolean,
): Intent {
    val spec = decisionPendingIntentSpec(confirmationId, allowed)
    return Intent(ConfirmNotifier.ACTION_DECIDE)
        .setClassName(context.packageName, ConfirmDecisionReceiver::class.java.name)
        .setPackage(context.packageName)
        .setData(Uri.parse(spec.dataUri))
        .putExtra(ConfirmNotifier.EXTRA_CONFIRMATION_ID, confirmationId)
        .putExtra(ConfirmNotifier.EXTRA_NONCE, nonce)
        .putExtra(ConfirmNotifier.EXTRA_ALLOWED, allowed)
}

private fun String.encodeAsHex(): String {
    return buildString(length * 4) {
        this@encodeAsHex.forEach { character ->
            val value = character.code
            append(HEX_DIGITS[(value ushr 12) and 0x0f])
            append(HEX_DIGITS[(value ushr 8) and 0x0f])
            append(HEX_DIGITS[(value ushr 4) and 0x0f])
            append(HEX_DIGITS[value and 0x0f])
        }
    }
}

private const val HEX_DIGITS = "0123456789abcdef"
private const val REQUEST_ALLOW = 0x9101
private const val REQUEST_DENY = 0x9102

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
 *   那是用户的明示选择，不是漏设的默认值；**当前尚无实际后果**（锁屏审批走不通）。
 *
 * **本类的实际适用面（2026-08-02 收窄）**：批次 2 现在验的是「屏幕亮着但人没盯着」——
 * heads-up 浮窗或下拉通知栏里点得到、点了能真的把决定送进网关。**锁屏那一面已移出**：
 * 锁屏下危险动作在前台身份这道门就结束了，这条通知根本不会被 post（spec §5.4）。
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
        timeoutMs: Long,
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
            // 通知确实 posted 且 actions=3 带 publicVersion、fullscreenIntent=null。
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
     * **但它当前一次都没被行使过，也就没有实际后果**（2026-08-02，spec §5.4/§5.5）：锁屏后目标
     * App 不再是活动应用窗口，危险动作在 `SafetyGate.requireKnownForeground` 就以 `E_BLOCKED`
     * 结束——**早于 `policy.assess`，所以卡和通知都不会出现**。免不免解锁根本没有机会体现。
     * 写清这一点是因为本仓反复栽在同一族坑里：**尚未生效的说法留在原地会被当成真相**，
     * 下一个人读到上面那段会以为免解锁已经在跑了。
     *
     * **重开条件**（任一命中就重新走 B 道）：手机曾离开用户控制（丢失、借出、被他人长时间持有），
     * 或出现一次真实的误批准。届时最小改动就是在这里按 `riskTier` 给 I 级挂上
     * `setAuthenticationRequired(true)`——接口就在手边，改动量很小，所以现在选宽松没有把路堵死。
     * **另加一条**：一旦锁屏审批本身被重新打通（语义意图那篇 spec 落地），这个选择**当场变成
     * 承重的**，应当在同一轮里重新确认一次，而不是沿用一个从未被行使过的决定。
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
                detailsPendingIntentFlags(),
            ),
        ).build()
    }

    /**
     * 回执 PendingIntent。四处刻意的写法：
     *
     * - **显式组件 + 限定本包**：广播只可能落到自家不导出的 receiver 上。
     * - **`FLAG_IMMUTABLE`**：拿到这个 PendingIntent 的人改不了里面的 extras，
     *   也就伪造不出"另一个 confirmationId / 另一个 allowed"。
     * - **唯一 data URI + 按 allowed 分开的 requestCode**：confirmationId 与决定共同构成身份，
     *   A 的句柄绝不会因 B 到来而被改写；允许与拒绝也不会互相覆盖。
     * - **`FLAG_CANCEL_CURRENT | FLAG_ONE_SHOT`**：同一次确认若重复 post，新句柄先取消旧句柄；
     *   任一句柄成功发送一次后也立即失效。旧确认即使迟到，arbiter 的 id/nonce 校验仍会拒绝。
     */
    internal fun decisionIntent(
        context: Context,
        confirmationId: String,
        nonce: String,
        allowed: Boolean,
    ): PendingIntent {
        val spec = decisionPendingIntentSpec(confirmationId, allowed)
        return PendingIntent.getBroadcast(
            context,
            spec.requestCode,
            buildDecisionIntent(context, confirmationId, nonce, allowed),
            spec.flags,
        )
    }

    /** 确认窗口之外再多给 15s：宁可晚一点被系统收走，不可早于人还能点的时候就消失。 */
    private const val TIMEOUT_SLACK_MS = 15_000L

    private const val REQUEST_DETAILS = 0x9103
}
