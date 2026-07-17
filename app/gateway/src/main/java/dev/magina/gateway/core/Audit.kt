package dev.magina.gateway.core

import android.content.Context
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.atomic.AtomicLong

/**
 * 审计 jsonl（spec §10）：每次工具调用一行——工具、参数、通道、结果码、耗时、
 * screen_capture 的 reason 也在参数里，事后可查每张原图为什么进了模型。
 * 落盘 getExternalFilesDir/audit/YYYYMMDD.jsonl，adb pull 可取，M3 任务面板回放用同一数据。
 */
class Audit(private val appContext: Context) {

    private val seq = AtomicLong(0)
    private val day = SimpleDateFormat("yyyyMMdd", Locale.US)
    private val iso = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS", Locale.US)

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
        runCatching {
            val dir = File(appContext.getExternalFilesDir(null), "audit").apply { mkdirs() }
            val line = JSONObject()
                .put("t", iso.format(Date()))
                .put("id", auditId)
                .put("tool", tool)
                .put("args", args)
                .put("result", okCode)
                .put("channel", channel)
                .put("ms", elapsedMs)
                .put("note", note)
            File(dir, "${day.format(Date())}.jsonl").appendText(line.toString() + "\n")
        }
    }
}
