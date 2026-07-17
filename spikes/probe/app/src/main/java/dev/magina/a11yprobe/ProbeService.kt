package dev.magina.a11yprobe

import android.accessibilityservice.AccessibilityService
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Bitmap
import android.graphics.Rect
import android.os.SystemClock
import android.util.Log
import android.view.Display
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import androidx.core.content.ContextCompat
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
import java.io.File
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors

/**
 * M1 Spike 探针（S1/S3/S4）。广播触发：
 *   adb shell am broadcast -a probe.DUMP   → S1：把当前所有交互窗口的节点树落盘
 *   adb shell am broadcast -a probe.SHOT   → S4：takeScreenshot 计时 → S3：ML Kit 中文 OCR 计时
 * 结果目录：/sdcard/Android/data/dev.magina.a11yprobe/files/
 */
class ProbeService : AccessibilityService() {

    companion object {
        private const val TAG = "a11yprobe"
        private const val ACTION_DUMP = "probe.DUMP"
        private const val ACTION_SHOT = "probe.SHOT"
    }

    private val executor = Executors.newSingleThreadExecutor()
    private val stamp get() = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date())

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                ACTION_DUMP -> dumpTrees()
                ACTION_SHOT -> shotAndOcr()
            }
        }
    }

    override fun onServiceConnected() {
        val filter = IntentFilter().apply {
            addAction(ACTION_DUMP)
            addAction(ACTION_SHOT)
        }
        // adb shell am broadcast 来自外部 → 必须 EXPORTED（探针仅自用实验，不做鉴权）
        ContextCompat.registerReceiver(this, receiver, filter, ContextCompat.RECEIVER_EXPORTED)
        Log.i(TAG, "probe connected; out dir = ${getExternalFilesDir(null)}")
    }

    override fun onDestroy() {
        runCatching { unregisterReceiver(receiver) }
        executor.shutdown()
        super.onDestroy()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) { /* 探针不处理事件流 */ }
    override fun onInterrupt() {}

    // ---------- S1：节点树落盘 ----------

    private fun dumpTrees() {
        val t0 = SystemClock.elapsedRealtime()
        val sb = StringBuilder()
        var total = 0
        var withText = 0

        sb.appendLine("== a11y-probe DUMP $stamp ==")
        val ws = windows
        sb.appendLine("windows=${ws.size}")
        for (w in ws) {
            val b = Rect().also { w.getBoundsInScreen(it) }
            sb.appendLine("-- window id=${w.id} type=${w.type} layer=${w.layer} pkg=${w.root?.packageName} title=${w.title} bounds=$b")
            w.root?.let { root ->
                val (n, t) = dumpNode(root, 0, sb)
                total += n; withText += t
            }
        }
        // 主窗口根节点单列一份（与 windows 遍历对照，防 retrieveInteractiveWindows 行为差异）
        sb.appendLine("-- rootInActiveWindow pkg=${rootInActiveWindow?.packageName}")

        val ms = SystemClock.elapsedRealtime() - t0
        val summary = "DUMP done: nodes=$total withText=$withText elapsed=${ms}ms"
        sb.appendLine("== $summary ==")
        val f = File(getExternalFilesDir(null), "dump-$stamp.txt")
        f.writeText(sb.toString())
        Log.i(TAG, "$summary -> ${f.name}")
    }

    /** 返回 (节点数, 带文本节点数)。深度限制防病态树。 */
    private fun dumpNode(node: AccessibilityNodeInfo, depth: Int, sb: StringBuilder): Pair<Int, Int> {
        if (depth > 60) return 0 to 0
        var total = 1
        val text = node.text?.toString().orEmpty()
        val desc = node.contentDescription?.toString().orEmpty()
        var withText = if (text.isNotEmpty() || desc.isNotEmpty()) 1 else 0

        val b = Rect().also { node.getBoundsInScreen(it) }
        val flags = buildString {
            if (node.isClickable) append("C")
            if (node.isEditable) append("E")
            if (node.isScrollable) append("S")
            if (node.isFocused) append("F")
        }
        sb.append("  ".repeat(depth))
            .append(node.className).append(' ')
            .append("id=").append(node.viewIdResourceName ?: "-").append(' ')
            .append("t=\"").append(text.take(60)).append("\" ")
            .append("d=\"").append(desc.take(60)).append("\" ")
            .append(flags).append(' ').append(b)
            .appendLine()

        for (i in 0 until node.childCount) {
            node.getChild(i)?.let {
                val (n, t) = dumpNode(it, depth + 1, sb)
                total += n; withText += t
            }
        }
        return total to withText
    }

    // ---------- S4 截图计时 + S3 OCR 计时 ----------

    private fun shotAndOcr() {
        val tag = stamp
        val t0 = SystemClock.elapsedRealtime()
        takeScreenshot(Display.DEFAULT_DISPLAY, executor, object : TakeScreenshotCallback {
            override fun onSuccess(result: ScreenshotResult) {
                val tShot = SystemClock.elapsedRealtime() - t0
                val hw = result.hardwareBuffer
                val bmp = Bitmap.wrapHardwareBuffer(hw, result.colorSpace)
                    ?.copy(Bitmap.Config.ARGB_8888, false)
                hw.close()
                if (bmp == null) {
                    Log.e(TAG, "SHOT wrap/copy failed")
                    return
                }
                val png = File(getExternalFilesDir(null), "shot-$tag.png")
                FileOutputStream(png).use { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }
                Log.i(TAG, "SHOT ok ${bmp.width}x${bmp.height} takeScreenshot=${tShot}ms -> ${png.name}")
                runOcr(bmp, tag, tShot)
            }

            override fun onFailure(errorCode: Int) {
                // 关注 ERROR_TAKE_SCREENSHOT_INTERVAL_TIME_SHORT：连发两次 SHOT 测节流窗口
                Log.e(TAG, "SHOT failed code=$errorCode elapsed=${SystemClock.elapsedRealtime() - t0}ms")
            }
        })
    }

    private fun runOcr(bmp: Bitmap, tag: String, tShotMs: Long) {
        val client = TextRecognition.getClient(ChineseTextRecognizerOptions.Builder().build())
        val t1 = SystemClock.elapsedRealtime()
        client.process(InputImage.fromBitmap(bmp, 0))
            .addOnSuccessListener { text ->
                val tOcr = SystemClock.elapsedRealtime() - t1
                val sb = StringBuilder()
                sb.appendLine("== a11y-probe OCR $tag ==")
                sb.appendLine("image=${bmp.width}x${bmp.height} takeScreenshot=${tShotMs}ms ocr=${tOcr}ms")
                var lines = 0
                for (block in text.textBlocks) for (line in block.lines) {
                    lines++
                    sb.appendLine("${line.boundingBox} conf=${"%.2f".format(line.confidence)} ${line.text}")
                }
                val summary = "OCR done: lines=$lines ocr=${tOcr}ms shot=${tShotMs}ms"
                sb.appendLine("== $summary ==")
                File(getExternalFilesDir(null), "ocr-$tag.txt").writeText(sb.toString())
                Log.i(TAG, summary)
                client.close()
            }
            .addOnFailureListener { e ->
                Log.e(TAG, "OCR failed", e)
                client.close()
            }
    }
}
