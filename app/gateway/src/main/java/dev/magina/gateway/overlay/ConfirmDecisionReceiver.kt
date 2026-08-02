package dev.magina.gateway.overlay

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import dev.magina.gateway.core.ApprovalOutcome
import dev.magina.gateway.core.ConfirmApprovalArbiter

/**
 * 通知栏审批回执的落点（批次 2）。
 *
 * **它是审批通道上唯一的入口，而且刻意做得极薄**：校验、裁决、记一行日志，没有别的。
 * 决定本身的胜负判定全在 [ConfirmApprovalArbiter]（纯 Kotlin、可离线单测），
 * 这里不复制任何一条判据——安全判定散成两份，迟早会漂移。
 *
 * manifest 里 `android:exported="false"`：只有本进程发的显式广播能到这里。
 * 加上 PendingIntent 的 `FLAG_IMMUTABLE` 与一次性 nonce，大脑没有任何路径能替真人点头。
 */
class ConfirmDecisionReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ConfirmNotifier.ACTION_DECIDE) return
        val confirmationId = intent.getStringExtra(ConfirmNotifier.EXTRA_CONFIRMATION_ID).orEmpty()
        val nonce = intent.getStringExtra(ConfirmNotifier.EXTRA_NONCE).orEmpty()
        // 没有默认值可言：extras 里读不到 allowed 就当没收到，绝不按"允许"兜底。
        if (!intent.hasExtra(ConfirmNotifier.EXTRA_ALLOWED)) return
        val allowed = intent.getBooleanExtra(ConfirmNotifier.EXTRA_ALLOWED, false)
        if (confirmationId.isEmpty() || nonce.isEmpty()) return

        val outcome = ConfirmApprovalArbiter.decide(confirmationId, nonce, allowed)
        if (outcome == ApprovalOutcome.ACCEPTED) {
            ConfirmNotifier.cancel(context)
        }
        // 只记处置结果与确认编号，**不记 nonce**：它是凭据，进了 logcat 就等于公开。
        Log.i(TAG, "approval decision id=$confirmationId outcome=$outcome")
    }

    private companion object {
        const val TAG = "GatewayApproval"
    }
}
