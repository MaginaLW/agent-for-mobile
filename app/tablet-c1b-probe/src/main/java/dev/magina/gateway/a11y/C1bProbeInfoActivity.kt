package dev.magina.gateway.a11y

import android.app.Activity
import android.os.Bundle
import android.widget.TextView
import dev.magina.gateway.R

/**
 * 只显示开启说明的启动页。vivo 会把没有启动入口的应用标为隐藏并拒绝绑定其无障碍服务，
 * 所以探针保留这一个可见入口。这里不读窗口、不调用任何动作、跳转或输入能力。
 */
class C1bProbeInfoActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(
            TextView(this).apply {
                setText(R.string.probe_info)
                textSize = 18f
                setPadding(48, 48, 48, 48)
            },
        )
    }
}
