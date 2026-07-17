package dev.magina.a11yprobe

import android.app.Activity
import android.os.Bundle
import android.widget.TextView

class MainActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(TextView(this).apply {
            textSize = 16f
            setPadding(48, 96, 48, 48)
            text = """
                a11y-probe（M1 Spike 探针）

                1. 设置 → 无障碍 → 开启「a11y-probe」
                2. 切到目标 app（如微信聊天页）
                3. PC 上触发：
                   adb shell am broadcast -a probe.DUMP   # S1 读树
                   adb shell am broadcast -a probe.SHOT   # S4 截图 + S3 OCR
                4. 取结果：
                   adb pull /sdcard/Android/data/dev.magina.a11yprobe/files/ .

                步骤详见 docs/runbooks/M1-spike-runbook.md
            """.trimIndent()
        })
    }
}
