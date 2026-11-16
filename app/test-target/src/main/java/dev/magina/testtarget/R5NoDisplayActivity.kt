package dev.magina.testtarget

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.os.Process
import android.os.SystemClock
import org.json.JSONObject

/** Synthetic receiver only; the private receipt does not establish foreground arrival. */
class R5NoDisplayActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val receivedAt = SystemClock.elapsedRealtime()
        try {
            if (intent.action != Intent.ACTION_VIEW) return
            val match = Regex("agent-testbench://r5/finish\\?nonce=(r5-[0-9a-f]{32})")
                .matchEntire(intent.dataString.orEmpty()) ?: return
            val receipt = JSONObject()
                .put("schema", 1)
                .put("source", "test_target_onCreate")
                .put("scenario", "r5_no_display_finish")
                .put("nonce", match.groupValues[1])
                .put("package", packageName)
                .put("component", componentName.className)
                .put("pid", Process.myPid())
                .put("process_start_elapsed_realtime_ms", Process.getStartElapsedRealtime())
                .put("received_elapsed_realtime_ms", receivedAt)
            openFileOutput("r5-finish-receipts.jsonl", MODE_APPEND).bufferedWriter().use {
                it.append(receipt.toString()).append('\n')
            }
        } finally {
            // Finish during onCreate, before onStart/onResume; no UI or alternate launch.
            finish()
        }
    }
}
