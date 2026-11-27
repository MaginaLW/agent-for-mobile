package dev.magina.gateway.core

import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile
import java.nio.charset.StandardCharsets

enum class AuditFilter(val label: String) {
    ALL("全部"),
    FAILURES("失败"),
    SAFETY("安全"),
    MACRO("宏子步"),
}

data class AuditRecord(
    val timestamp: String,
    val id: String,
    val tool: String,
    val result: String,
    val channel: String,
    val elapsedMs: Long,
    val note: String,
    val argsSummary: String,
    val isMacroChild: Boolean,
    val isSafetyEvent: Boolean,
    val isFailure: Boolean,
)

data class AuditDaySummary(
    val dayKey: String,
    val totalCount: Int,
    val okCount: Int,
    val failureCount: Int,
    val safetyCount: Int,
    val macroCount: Int,
    val malformedLines: Int,
)

data class AuditPage(
    val dayKey: String?,
    val availableDays: List<String>,
    val summary: AuditDaySummary?,
    val records: List<AuditRecord>,
)

/**
 * 纯 Kotlin 只读审计日志读取器。
 *
 * 仅从 [Audit.auditDirectory] 读取 `YYYYMMDD.jsonl` 尾部有界切片，容错跳过损坏行，
 * 并对展示用参数做二次脱敏和长度截断，不修改或删除任何审计文件。
 */
object AuditLogReader {
    const val DEFAULT_LIMIT = 80
    const val MAX_LIMIT = 500
    const val MAX_READ_BYTES = 1_048_576L
    private const val ARGS_SUMMARY_LIMIT = 120

    private val DAY_FILE_REGEX = Regex("^(\\d{8})\\.jsonl$")
    private val SAFETY_RESULTS = setOf(
        ErrorCode.E_BLOCKED.name,
        ErrorCode.E_CONFIRM_REQUIRED.name,
        ErrorCode.E_CONFIRM_TIMEOUT.name,
        ErrorCode.E_STALE_REF.name,
    )
    private val SENSITIVE_ARG_KEYS = setOf("text", "message", "content", "token", "authorization")

    fun listDays(dir: File): List<String> {
        if (!dir.exists() || !dir.isDirectory) return emptyList()
        val files = dir.listFiles() ?: return emptyList()
        return files.mapNotNull { file ->
            if (!file.isFile) return@mapNotNull null
            DAY_FILE_REGEX.matchEntire(file.name)?.groupValues?.get(1)
        }.sortedDescending()
    }

    fun readDay(
        dir: File,
        requestedDay: String? = null,
        filter: AuditFilter = AuditFilter.ALL,
        limit: Int = DEFAULT_LIMIT,
    ): AuditPage {
        val availableDays = listDays(dir)
        if (availableDays.isEmpty()) {
            return AuditPage(dayKey = null, availableDays = emptyList(), summary = null, records = emptyList())
        }
        val dayKey = requestedDay?.takeIf { it in availableDays } ?: availableDays.first()
        val file = File(dir, "$dayKey.jsonl")
        if (!file.isFile) {
            return AuditPage(dayKey = dayKey, availableDays = availableDays, summary = null, records = emptyList())
        }

        val cappedLimit = limit.coerceIn(1, MAX_LIMIT)
        val lines = readBoundedLines(file)
        var total = 0
        var okCount = 0
        var failureCount = 0
        var safetyCount = 0
        var macroCount = 0
        var malformedLines = 0
        val parsed = ArrayList<AuditRecord>()

        for (rawLine in lines) {
            val trimmed = rawLine.trim()
            if (trimmed.isEmpty()) continue
            val record = parseLine(trimmed)
            if (record == null) {
                malformedLines++
                continue
            }
            total++
            if (record.isFailure) failureCount++ else okCount++
            if (record.isSafetyEvent) safetyCount++
            if (record.isMacroChild) macroCount++
            parsed.add(record)
        }

        val filtered = parsed.asReversed()
            .filter { matchesFilter(it, filter) }
            .take(cappedLimit)

        val summary = AuditDaySummary(
            dayKey = dayKey,
            totalCount = total,
            okCount = okCount,
            failureCount = failureCount,
            safetyCount = safetyCount,
            macroCount = macroCount,
            malformedLines = malformedLines,
        )
        return AuditPage(
            dayKey = dayKey,
            availableDays = availableDays,
            summary = summary,
            records = filtered,
        )
    }

    internal fun summarizeArgs(args: JSONObject?): String {
        if (args == null || args.length() == 0) return ""
        val joined = args.keys().asSequence().toList().sorted().joinToString(", ") { key ->
            val rawValue = args.opt(key)
            if (key.lowercase() in SENSITIVE_ARG_KEYS) {
                val len = rawValue?.toString()?.length ?: 0
                "$key=<redacted:$len>"
            } else {
                val valueText = when (rawValue) {
                    null, JSONObject.NULL -> "null"
                    is String -> rawValue.replace('\n', ' ').replace('\r', ' ').take(40)
                    else -> rawValue.toString().take(40)
                }
                "$key=$valueText"
            }
        }
        return if (joined.length <= ARGS_SUMMARY_LIMIT) {
            joined
        } else {
            joined.take(ARGS_SUMMARY_LIMIT - 1) + "…"
        }
    }

    private fun parseLine(line: String): AuditRecord? {
        val obj = runCatching { JSONObject(line) }.getOrNull() ?: return null
        val tool = obj.optString("tool").trim()
        val result = obj.optString("result").trim()
        if (tool.isEmpty() || result.isEmpty()) return null
        val note = obj.optString("note")
        val isMacroChild = note.contains("origin=macro")
        val isSafetyEvent = result in SAFETY_RESULTS ||
            note.contains("confirmation=") ||
            note.contains("risk=confirmation_required")
        return AuditRecord(
            timestamp = obj.optString("t"),
            id = obj.optString("id"),
            tool = tool,
            result = result,
            channel = obj.optString("channel"),
            elapsedMs = obj.optLong("ms", 0L),
            note = note,
            argsSummary = summarizeArgs(obj.optJSONObject("args")),
            isMacroChild = isMacroChild,
            isSafetyEvent = isSafetyEvent,
            isFailure = result != "OK",
        )
    }

    private fun matchesFilter(record: AuditRecord, filter: AuditFilter): Boolean = when (filter) {
        AuditFilter.ALL -> true
        AuditFilter.FAILURES -> record.isFailure
        AuditFilter.SAFETY -> record.isSafetyEvent
        AuditFilter.MACRO -> record.isMacroChild
    }

    private fun readBoundedLines(file: File): List<String> {
        val length = file.length()
        if (length <= 0L) return emptyList()
        if (length <= MAX_READ_BYTES) {
            return runCatching { file.readLines(StandardCharsets.UTF_8) }.getOrDefault(emptyList())
        }
        return runCatching {
            RandomAccessFile(file, "r").use { raf ->
                val start = length - MAX_READ_BYTES
                raf.seek(start)
                val buf = ByteArray(MAX_READ_BYTES.toInt())
                var totalRead = 0
                while (totalRead < buf.size) {
                    val n = raf.read(buf, totalRead, buf.size - totalRead)
                    if (n <= 0) break
                    totalRead += n
                }
                val text = String(buf, 0, totalRead, StandardCharsets.UTF_8)
                // 从文件中间截取时丢弃首行残片，避免把半个 UTF-8/JSON 行计成损坏行。
                val firstNewline = text.indexOf('\n')
                val clean = if (firstNewline >= 0) text.substring(firstNewline + 1) else ""
                clean.lines()
            }
        }.getOrDefault(emptyList())
    }
}
