package dev.magina.gateway.a11y

import android.accessibilityservice.AccessibilityService
import android.view.accessibility.AccessibilityEvent
import java.util.concurrent.atomic.AtomicLong

/**
 * C1b 专用的最小只读 service。它只公开当前 service identity 与事件 revision；窗口、节点、
 * display/IME 状态均由 C1b source 在采集边界读取。这里没有动作、手势、截图或输入能力。
 */
class GatewayA11yService : AccessibilityService() {
    private val eventRevision = AtomicLong(0)

    val revision: Long
        get() = eventRevision.get()

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event != null) eventRevision.incrementAndGet()
    }

    override fun onInterrupt() = Unit

    override fun onDestroy() {
        if (instance === this) instance = null
        super.onDestroy()
    }

    companion object {
        @Volatile
        var instance: GatewayA11yService? = null
            private set
    }
}
