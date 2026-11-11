package dev.magina.testtarget

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.os.Bundle
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

/** Synthetic, offline UI. No permission, account, network, provider, or approval channel. */
class MainActivity : Activity() {
    private lateinit var content: LinearLayout

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        showIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        showIntent(intent)
    }

    private fun showIntent(source: Intent) {
        val uri = source.data
        val route = when {
            uri == null -> "list"
            uri.scheme == "agent-testbench" && uri.host == "target" -> uri.path?.trim('/')
            else -> null
        }
        show(when (route) {
            "list", "search", "conversation", "opaque", "degenerate", "ime" -> route
            else -> "invalid"
        })
    }

    private fun show(route: String) {
        content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(32, 40, 32, 32)
        }
        setContentView(ScrollView(this).apply { addView(content) })
        label("本地测试靶标 · $route", R.id.target_title)
        label("仅含合成文本；没有真实联系人或外发功能。")

        when (route) {
            "list" -> {
                button("搜索会话") { show("search") }
                button("测试联系人甲") { show("conversation") }
                button("测试联系人乙") { show("conversation") }
                button("不透明子树") { show("opaque") }
                button("退化应用节点") { show("degenerate") }
                button("输入法场景") { show("ime") }
            }
            "search" -> {
                val search = input("输入测试会话名", R.id.target_search_input)
                label("可搜索：测试联系人甲")
                button("查找测试会话") {
                    if (search.text.toString() == "测试联系人甲") show("conversation")
                    else label("未找到测试会话")
                }
            }
            "conversation", "ime" -> conversation(showIme = route == "ime")
            "opaque" -> {
                label("下方内容使用 Canvas 绘制；子树不向无障碍暴露文字。")
                content.addView(OpaqueContent(this), LinearLayout.LayoutParams(-1, 520))
            }
            "degenerate" -> {
                label("下方是应用提供的不可见/零矩形节点，不是系统窗口 root。")
                content.addView(DegenerateContent(this), LinearLayout.LayoutParams(-1, 160))
            }
            else -> label("未知靶标路由；未执行任何动作。")
        }
    }

    private fun conversation(showIme: Boolean) {
        label("测试联系人甲")
        label("合成消息：列表中的同名项不能代替当前会话标题。")
        val editor = input("输入测试消息", R.id.target_composer)
        var actionCount = 0
        val count = label("本地发送回调次数：0", R.id.target_action_count)
        button("发送（仅本地计数）", R.id.target_send) {
            actionCount += 1
            count.text = "本地发送回调次数：$actionCount"
        }
        if (showIme) {
            editor.requestFocus()
            editor.post {
                (getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager)
                    .showSoftInput(editor, InputMethodManager.SHOW_IMPLICIT)
            }
        }
    }

    private fun label(value: String, viewId: Int = View.NO_ID): TextView = TextView(this).apply {
        id = viewId
        text = value
        textSize = 19f
        setPadding(0, 12, 0, 12)
        content.addView(this)
    }

    private fun input(hintText: String, viewId: Int): EditText = EditText(this).apply {
        id = viewId
        hint = hintText
        isSingleLine = true
        isSaveEnabled = false
        content.addView(this)
    }

    private fun button(value: String, viewId: Int = View.NO_ID, action: () -> Unit) {
        content.addView(Button(this).apply {
            id = viewId
            text = value
            setOnClickListener { action() }
        })
    }
}

private class OpaqueContent(context: Context) : View(context) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.BLACK; textSize = 34f }

    init { importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        canvas.drawColor(Color.LTGRAY)
        canvas.drawText("测试联系人甲", 24f, 80f, paint)
        canvas.drawText("合成内容：可见画面，不透明子树", 24f, 160f, paint)
    }
}

private class DegenerateContent(context: Context) : View(context) {
    init {
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_YES
        contentDescription = "合成退化节点"
    }

    override fun onInitializeAccessibilityNodeInfo(info: AccessibilityNodeInfo) {
        super.onInitializeAccessibilityNodeInfo(info)
        info.isVisibleToUser = false
        info.setBoundsInScreen(Rect(0, 0, 0, 0))
        info.setBoundsInParent(Rect(0, 0, 0, 0))
    }
}
