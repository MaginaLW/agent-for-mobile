package dev.magina.gateway.a11y

import java.util.UUID

/** ref 的来源决定对外前缀；前缀仅供人读，身份由 session + snapshot generation 保证。 */
internal enum class UiRefSource(val prefix: Char) {
    A11Y('e'),
    OCR('o'),
}

/**
 * 一次 snapshot 的 ref 命名空间。
 *
 * [sessionId] 防止服务进程重启后把旧 ref 绑定到新节点，[generation] 防止同一进程内下一次
 * snapshot 复用 `e1`/`o1`。两者都不是授权凭据，只负责让 ref 在时间上不可重绑定。
 */
internal data class SnapshotRefBatch internal constructor(
    internal val sessionId: String,
    internal val generation: Long,
    val revision: Long,
) {
    internal fun reference(source: UiRefSource, ordinal: Int): String {
        require(ordinal > 0) { "ref ordinal 必须为正数" }
        return "${source.prefix}:$sessionId:${generation.toString(36)}:$ordinal"
    }
}

internal enum class UiRefLookupState {
    CURRENT,
    STALE,
    MISSING,
}

internal data class UiRefLookup<T>(
    val state: UiRefLookupState,
    val value: T? = null,
)

/**
 * 只保存当前 snapshot 的 ref。所有入口自身同步，因此即使调用方漏加锁也不会出现 clear/get 竞态；
 * GatewayA11yService 仍会把整段 snapshot 与 resolve 标成同步，以覆盖遍历和 OCR 更新的完整临界区。
 */
internal class SnapshotRefRegistry<T>(
    private val sessionId: String = UUID.randomUUID().toString().replace("-", "").take(16),
) {
    init {
        require(sessionId.matches(Regex("[A-Za-z0-9]+"))) { "sessionId 只能含字母与数字" }
    }

    private val entries = LinkedHashMap<String, T>()
    private var generation = 0L
    private var activeBatch: SnapshotRefBatch? = null

    @Synchronized
    fun beginSnapshot(revision: Long): SnapshotRefBatch {
        check(generation != Long.MAX_VALUE) { "snapshot generation 已耗尽" }
        generation += 1
        entries.clear()
        return SnapshotRefBatch(sessionId, generation, revision).also { activeBatch = it }
    }

    @Synchronized
    fun bind(batch: SnapshotRefBatch, source: UiRefSource, ordinal: Int, value: T): String {
        check(batch == activeBatch) { "不能向已过期 snapshot 绑定 ref" }
        val ref = batch.reference(source, ordinal)
        check(entries.putIfAbsent(ref, value) == null) { "同一 snapshot 内 ref 重复: $ref" }
        return ref
    }

    @Synchronized
    fun lookup(ref: String): UiRefLookup<T> {
        entries[ref]?.let { return UiRefLookup(UiRefLookupState.CURRENT, it) }
        val parsed = parseOwnedRef(ref) ?: return UiRefLookup(UiRefLookupState.MISSING)
        return if (parsed.generation != activeBatch?.generation) {
            UiRefLookup(UiRefLookupState.STALE)
        } else {
            UiRefLookup(UiRefLookupState.MISSING)
        }
    }

    @Synchronized
    fun current(ref: String): T? = entries[ref]

    @Synchronized
    fun replace(ref: String, value: T): Boolean {
        if (!entries.containsKey(ref)) return false
        entries[ref] = value
        return true
    }

    @Synchronized
    fun currentEntries(): List<Pair<String, T>> = entries.map { it.key to it.value }

    private data class ParsedRef(val generation: Long)

    private fun parseOwnedRef(ref: String): ParsedRef? {
        val parts = ref.split(':')
        if (parts.size != 4 || parts[0].length != 1) return null
        if (parts[0][0] != UiRefSource.A11Y.prefix && parts[0][0] != UiRefSource.OCR.prefix) return null
        if (parts[1] != sessionId || parts[3].toIntOrNull()?.let { it > 0 } != true) return null
        val parsedGeneration = parts[2].toLongOrNull(36) ?: return null
        return ParsedRef(parsedGeneration)
    }
}
