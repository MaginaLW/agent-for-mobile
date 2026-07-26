package dev.magina.gateway.core

import android.content.Context
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.atomic.AtomicLong

/** 审计参数必须先复制；type_text 只落长度和摘要，绝不落输入明文。 */
internal fun sanitizeAuditArgs(tool: String, args: JSONObject): JSONObject {
    val sanitized = JSONObject(args.toString())
    if (tool == "type_text") {
        val text = sanitized.optString("text")
        sanitized.remove("text")
        sanitized.put("text_length", text.length)
        sanitized.put("text_sha256", InputCommitEvidence.sha256(text))
    }
    return sanitized
}

internal fun buildAuditLine(
    timestamp: String,
    auditId: String,
    tool: String,
    args: JSONObject,
    okCode: String,
    channel: String,
    elapsedMs: Long,
    note: String,
): JSONObject = JSONObject()
    .put("t", timestamp)
    .put("id", auditId)
    .put("tool", tool)
    .put("args", args)
    .put("result", okCode)
    .put("channel", channel)
    .put("ms", elapsedMs)
    .put("note", note)

/**
 * 审计 jsonl（spec §10）：每次工具调用一行——工具、参数、通道、结果码、耗时、
 * screen_capture 的 reason 也在参数里，事后可查每张原图为什么进了模型。
 * 落盘 getExternalFilesDir/audit/YYYYMMDD.jsonl，adb pull 可取，M3 任务面板回放用同一数据。
 */
class Audit(
    /** 审计目录来源。抽成 lambda 是为了能在纯 JVM 单测里注入临时目录与故意失败的实现。 */
    private val dirProvider: () -> File,
) {
    constructor(appContext: Context) : this({ File(appContext.getExternalFilesDir(null), "audit") })

    private val seq = AtomicLong(0)
    private val day = SimpleDateFormat("yyyyMMdd", Locale.US)
    private val iso = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS", Locale.US)
    private val failures = AtomicLong(0)
    private var prunedDay: String? = null

    /**
     * 写盘失败次数。
     *
     * 原实现整个裹在 `runCatching {}` 里，失败连个痕迹都不留——而审计是安全硬门的证据链，
     * **"一切正常，只是没有证据"是最坏的失败模式**：事后回看以为动作没发生过。
     * 这个计数会进 ctx，让大脑当场看见证据链断了（`run-as` 读不到 external files 那次，
     * 采集坏了好几天没人知道，就是同一类问题的另一面）。
     */
    val writeFailures: Long get() = failures.get()

    fun nextId(): String = "a-%06d".format(seq.incrementAndGet())

    @Synchronized
    fun write(
        auditId: String,
        tool: String,
        args: JSONObject,
        okCode: String,          // "OK" 或 ErrorCode 名
        channel: String,
        elapsedMs: Long,
        note: String = "",
    ) {
        val today = day.format(Date())
        val outcome = runCatching {
            val dir = dirProvider().apply { mkdirs() }
            val line = buildAuditLine(
                timestamp = iso.format(Date()),
                auditId = auditId,
                tool = tool,
                args = args,
                okCode = okCode,
                channel = channel,
                elapsedMs = elapsedMs,
                note = note,
            )
            File(dir, "$today.jsonl").appendText(line.toString() + "\n")
            dir
        }
        // 仍然不让审计失败把工具调用带崩（证据缺失比动作失败轻），但必须留下痕迹。
        if (outcome.isFailure) {
            failures.incrementAndGet()
            return
        }
        // 清理**独立于写盘成败计数**：行已经落下去了，清理再出问题也不该让
        // ctx.audit_write_failures 报警——那个信号一旦有假阳性就没人信了。
        prunedDay?.let { if (it == today) return }
        prunedDay = today
        runCatching { pruneExpired(outcome.getOrThrow()) }
    }

    /**
     * 一天一个文件、永不清理会无限长下去。只保留最近 [RETENTION_DAYS] 天。
     *
     * 每天只跑一次：原来每写一行都 `listFiles` + 每文件一次 `lastModified()`，稳态下
     * 每次工具调用要在 external files（FUSE）上做 30 次 stat，纯属白烧。
     */
    private fun pruneExpired(dir: File) {
        val cutoff = System.currentTimeMillis() - RETENTION_DAYS * DAY_MS
        dir.listFiles { f -> f.isFile && f.name.endsWith(".jsonl") }
            ?.filter { it.lastModified() < cutoff }
            ?.forEach { it.delete() }
    }

    companion object {
        const val RETENTION_DAYS = 30L
        private const val DAY_MS = 24L * 60 * 60 * 1000
    }
}
