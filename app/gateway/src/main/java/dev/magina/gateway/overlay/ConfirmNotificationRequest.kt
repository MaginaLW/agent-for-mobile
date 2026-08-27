package dev.magina.gateway.overlay

import dev.magina.gateway.core.RiskTier

/**
 * 推一条与确认卡并行显示的证据/拒绝通知所需的全部信息（批次 2）。
 *
 * [nonce] 是**一次性拒绝回执凭据**：只存在于本进程内存与 PendingIntent 的 extras 里，
 * 不进 MCP 信封、不进 trace、不进审计、不进日志——大脑没有任何路径能拿到它。
 * 它与大脑调工具用的 gateway token 是两套东西，从不共用（接缝 1）。
 */
data class ConfirmNotificationRequest(
    val confirmationId: String,
    val nonce: String,
    val riskTier: RiskTier,
    /** 动作短语，进锁屏那一行，例如「发送消息」。不含任何输入内容。 */
    val action: String,
    /** 目标会话 label，进锁屏那一行。是收件人，不是消息内容。 */
    val target: String,
    /** 目标包名，只用于查撤回窗口时长。 */
    val targetPackage: String,
    /** 明文预览；**只进需要解锁的展开态**，绝不进 public version。 */
    val preview: String?,
)
