package dev.magina.gateway.core

import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/** UI 写调用从安全检查开始到 executor 返回为止只能有一个在途。 */
class UiMutationCoordinator {
    private val lock = ReentrantLock(true)

    fun <T> runExclusive(block: () -> T): T = lock.withLock(block)
}

internal fun shouldSerializeUiCall(
    level: Level?,
    toolName: String,
    scrollSearch: Boolean,
): Boolean = level != null && (
    level != Level.R || (toolName == "ui_find" && scrollSearch)
    )

/** 不可读输入无法证明未被间接改写：所有写边界先清证据，Enter 为执行前复检的唯一例外。 */
internal fun invalidateInputEvidenceForMutation(
    store: InputCommitEvidenceStore,
    level: Level?,
    toolName: String,
    key: String? = null,
    @Suppress("UNUSED_PARAMETER") action: String? = null,
    scrollSearch: Boolean = false,
): Boolean {
    val invalidates = shouldSerializeUiCall(level, toolName, scrollSearch) &&
        !(toolName == "press_key" && key.equals("enter", ignoreCase = true))
    if (invalidates) store.clear()
    return invalidates
}

/**
 * 已准备业务目标只允许沿 macro -> type_text -> press_key(enter) 链路存活。
 * macro 自身在开始时清旧值，成功后再记录新值；其他 UI mutation 一律失效。
 */
internal fun invalidatePreparedTargetForMutation(
    store: PreparedTargetEvidenceStore,
    level: Level?,
    toolName: String,
    key: String? = null,
    scrollSearch: Boolean = false,
): Boolean {
    val preserves = toolName == "type_text" ||
        (toolName == "press_key" && key.equals("enter", ignoreCase = true))
    val invalidates = shouldSerializeUiCall(level, toolName, scrollSearch) && !preserves
    if (invalidates) store.clear()
    return invalidates
}

internal fun preparedTargetSurvivesTypeText(
    before: PreparedTargetEvidence?,
    after: PreparedTargetEvidence?,
    input: InputCommitEvidence?,
    succeeded: Boolean,
): Boolean = succeeded && before != null && before == after &&
    input != null && input.identity == after.identity
