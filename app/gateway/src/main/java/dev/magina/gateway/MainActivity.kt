package dev.magina.gateway

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import dev.magina.gateway.a11y.GatewayA11yService
import dev.magina.gateway.mcp.McpServer

/** 首装引导 + 状态面板（M1a 简版；任务面板/回放按主设计排 M3）。 */
class MainActivity : Activity() {

    private lateinit var status: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Gateway.init(this)

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(48, 64, 48, 48)
        }
        status = TextView(this).apply { textSize = 14f }
        root.addView(status)

        fun button(label: String, onClick: () -> Unit) {
            root.addView(Button(this).apply { text = label; setOnClickListener { onClick() } })
        }

        button("① 授予运行权限（蓝牙/通知/媒体）") {
            requestPermissions(
                arrayOf(
                    android.Manifest.permission.BLUETOOTH_CONNECT,
                    android.Manifest.permission.POST_NOTIFICATIONS,
                    android.Manifest.permission.READ_MEDIA_IMAGES,
                ),
                1,
            )
        }
        button("② 开启无障碍服务") {
            startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
        }
        button("③ 启用网关输入法") {
            startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS))
        }
        button("④ 授予悬浮窗（确认层）") {
            startActivity(
                Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName")),
            )
        }
        button("⑤ 启动网关服务") { GatewayService.start(this); status.postDelayed({ refresh() }, 500) }
        button("停止网关服务") { GatewayService.stop(this); status.postDelayed({ refresh() }, 500) }
        button("复制 token") {
            val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            cm.setPrimaryClip(ClipData.newPlainText("gateway-token", Gateway.token))
            Toast.makeText(this, "token 已复制", Toast.LENGTH_SHORT).show()
        }

        setContentView(ScrollView(this).apply { addView(root) })
    }

    override fun onResume() {
        super.onResume()
        refresh()
    }

    private fun refresh() {
        status.text = buildString {
            appendLine("== 执行网关 0.1.0-m1a ==\n")
            appendLine("MCP:  http://127.0.0.1:${Gateway.DEFAULT_PORT}/mcp")
            appendLine("服务:  ${if (McpServer.running) "运行中 ✅" else "未启动"}")
            appendLine("无障碍: ${if (GatewayA11yService.instance != null) "✅" else "未开启"}")
            appendLine("输入法: ${if (Gateway.imeEnabled()) "已启用 ✅" else "未启用"}")
            appendLine("悬浮窗: ${if (Settings.canDrawOverlays(this@MainActivity)) "✅" else "未授权"}")
            appendLine("能力位: ${Gateway.caps()}")
            appendLine("\ntoken: ${Gateway.token}")
            appendLine("\nPC 侧接入：")
            appendLine("adb forward tcp:${Gateway.DEFAULT_PORT} tcp:${Gateway.DEFAULT_PORT}")
            appendLine("然后 claude --mcp-config configs/gateway-mcp.json")
        }
    }
}
