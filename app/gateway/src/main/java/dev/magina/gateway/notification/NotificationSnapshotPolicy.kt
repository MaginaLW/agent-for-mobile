package dev.magina.gateway.notification

import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.GatewayError
import dev.magina.gateway.core.InputCommitEvidence
import org.json.JSONArray
import org.json.JSONObject

const val VISIBILITY_SECRET: Int = -1

enum class NotificationAccessState {
    PERMISSION_MISSING,
    SERVICE_DISCONNECTED,
    QUERY_FAILED_SECURITY,
    QUERY_FAILED_ERROR,
    CONNECTED,
}

data class RawNotificationRecord(
    val key: String,
    val packageName: String,
    val postTime: Long,
    val title: String?,
    val text: String?,
    val visibility: Int,
    val ongoing: Boolean,
    val hasActions: Boolean,
    val hasRemoteInput: Boolean,
)

data class NotificationListQuery(
    val targetPackage: String?,
    val limit: Int,
)

/**
 * L3 通知只读快照纯 Kotlin 策略层（零 android.* 依赖，供 JVM 单测全覆盖）。
 */
object NotificationSnapshotPolicy {

    const val DEFAULT_LIMIT = 20
    const val MIN_LIMIT = 1
    const val MAX_LIMIT = 50
    const val MAX_TITLE_LENGTH = 120
    const val MAX_TEXT_LENGTH = 240

    private val ALLOWED_KEYS = setOf("package", "limit")

    fun parseQuery(
        args: JSONObject,
        resolvePackage: (String) -> String,
        isBlockedApp: (String?) -> Boolean,
    ): NotificationListQuery {
        val unknownKeys = args.keys().asSequence().filter { it !in ALLOWED_KEYS }.toList()
        if (unknownKeys.isNotEmpty()) {
            throw GatewayError(
                ErrorCode.E_INVALID_ARG,
                "notifications_list 存在未声明参数：${unknownKeys.joinToString(", ")}",
                channel = "notif",
                retryable = false,
            )
        }

        val rawPkg = args.opt("package")
        val targetPackage = when (rawPkg) {
            null, JSONObject.NULL -> null
            is String -> {
                val trimmed = rawPkg.trim()
                if (trimmed.isEmpty()) {
                    null
                } else {
                    val resolved = resolvePackage(trimmed)
                    if (isBlockedApp(resolved)) {
                        throw GatewayError(
                            ErrorCode.E_BLOCKED,
                            "目标应用（$resolved）属于敏感黑名单，拒绝读取通知",
                            channel = "safety",
                            retryable = false,
                            fallback = "按站规不得读取敏感黑名单应用通知",
                        )
                    }
                    resolved
                }
            }
            else -> throw GatewayError(
                ErrorCode.E_INVALID_ARG,
                "package 参数必须为字符串",
                channel = "notif",
                retryable = false,
            )
        }

        val rawLimit = args.opt("limit")
        val limit = when (rawLimit) {
            null, JSONObject.NULL -> DEFAULT_LIMIT
            is Int -> {
                if (rawLimit !in MIN_LIMIT..MAX_LIMIT) {
                    throw invalidLimitError()
                }
                rawLimit
            }
            is Long -> {
                if (rawLimit !in MIN_LIMIT.toLong()..MAX_LIMIT.toLong()) {
                    throw invalidLimitError()
                }
                rawLimit.toInt()
            }
            else -> throw invalidLimitError()
        }

        return NotificationListQuery(targetPackage = targetPackage, limit = limit)
    }

    fun evaluate(
        state: NotificationAccessState,
        records: List<RawNotificationRecord>,
        query: NotificationListQuery,
        selfPackageName: String,
        isBlockedApp: (String?) -> Boolean,
    ): JSONObject {
        when (state) {
            NotificationAccessState.PERMISSION_MISSING -> throw GatewayError(
                ErrorCode.E_PERM_MISSING,
                "未授予执行网关通知使用权（NotificationListenerService）",
                channel = "notif",
                retryable = false,
                fallback = "在网关主界面点「开启通知使用权（L3 只读通道）」并授权后重试",
            )
            NotificationAccessState.QUERY_FAILED_SECURITY -> throw GatewayError(
                ErrorCode.E_PERM_MISSING,
                "读取系统通知被系统拒绝（SecurityException）",
                channel = "notif",
                retryable = false,
                fallback = "在系统设置重新确认「执行网关」的通知使用权后重试",
            )
            NotificationAccessState.SERVICE_DISCONNECTED -> throw GatewayError(
                ErrorCode.E_CHANNEL_DOWN,
                "通知监听服务未连接（GatewayNotificationListenerService 未就绪）",
                channel = "notif",
                retryable = false,
                fallback = "确认已开启通知使用权；若刚授权或系统回收，请等待绑定或重新开关通知使用权后重试",
            )
            NotificationAccessState.QUERY_FAILED_ERROR -> throw GatewayError(
                ErrorCode.E_CHANNEL_DOWN,
                "读取系统活动通知失败",
                channel = "notif",
                retryable = false,
                fallback = "稍后重试；若持续失败请在网关主界面核对通知读取通道状态",
            )
            NotificationAccessState.CONNECTED -> Unit
        }

        var selfExcludedCount = 0
        var blockedFilteredCount = 0
        val matched = ArrayList<ProjectedNotification>()

        for (record in records) {
            if (record.packageName == selfPackageName) {
                selfExcludedCount += 1
                continue
            }
            if (isBlockedApp(record.packageName)) {
                blockedFilteredCount += 1
                continue
            }
            if (query.targetPackage != null && record.packageName != query.targetPackage) {
                continue
            }
            matched.add(project(record))
        }

        matched.sortWith(
            compareByDescending<ProjectedNotification> { it.postTime }
                .thenBy { it.id },
        )

        val limited = matched.take(query.limit)
        val notificationsJson = JSONArray()
        limited.forEach { notificationsJson.put(it.json) }

        return JSONObject()
            .put("notifications", notificationsJson)
            .put("count", limited.size)
            .put("matched_count", matched.size)
            .put("total_active", records.size)
            .put("blocked_filtered_count", blockedFilteredCount)
            .put("self_excluded_count", selfExcludedCount)
            .put("truncated", matched.size > query.limit)
            .put("filter_package", query.targetPackage ?: JSONObject.NULL)
            .put("limit", query.limit)
            .put("channel_state", "connected")
    }

    private data class ProjectedNotification(
        val id: String,
        val postTime: Long,
        val json: JSONObject,
    )

    private fun project(record: RawNotificationRecord): ProjectedNotification {
        val id = "n-" + InputCommitEvidence.sha256(record.key).take(12)
        val title: String
        val text: String
        val contentRedacted: Boolean
        val redactionReason: String?

        if (record.visibility == VISIBILITY_SECRET) {
            title = ""
            text = ""
            contentRedacted = true
            redactionReason = "secret_visibility"
        } else {
            title = truncateWithEllipsis(collapseWhitespace(record.title), MAX_TITLE_LENGTH)
            text = truncateWithEllipsis(collapseWhitespace(record.text), MAX_TEXT_LENGTH)
            if (title.isEmpty() && text.isEmpty()) {
                contentRedacted = true
                redactionReason = "content_unavailable"
            } else {
                contentRedacted = false
                redactionReason = null
            }
        }

        val json = JSONObject()
            .put("id", id)
            .put("package", record.packageName)
            .put("post_time", record.postTime)
            .put("title", title)
            .put("text", text)
            .put("ongoing", record.ongoing)
            .put("has_actions", record.hasActions)
            .put("has_remote_input", record.hasRemoteInput)
            .put("content_redacted", contentRedacted)
            .put("redaction_reason", redactionReason ?: JSONObject.NULL)

        return ProjectedNotification(id = id, postTime = record.postTime, json = json)
    }

    private fun invalidLimitError() = GatewayError(
        ErrorCode.E_INVALID_ARG,
        "limit 必须为 $MIN_LIMIT..$MAX_LIMIT 的整数",
        channel = "notif",
        retryable = false,
    )

    private fun collapseWhitespace(raw: String?): String {
        if (raw.isNullOrEmpty()) return ""
        val out = StringBuilder(raw.length)
        var pendingSpace = false
        for (ch in raw) {
            if (ch.isWhitespace()) {
                if (out.isNotEmpty()) pendingSpace = true
            } else {
                if (pendingSpace) {
                    out.append(' ')
                    pendingSpace = false
                }
                out.append(ch)
            }
        }
        return out.toString()
    }

    private fun truncateWithEllipsis(value: String, maxLen: Int): String =
        if (value.length <= maxLen) value else value.take(maxLen - 1) + "…"
}
