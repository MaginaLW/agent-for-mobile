package dev.magina.gateway.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** 通知栏审批三层文案（批次 2，B 道决定一 + L1 脱敏）。 */
class ConfirmNotificationContentTest {

    private val preview = "转账 5000 元给张三"

    /**
     * **本类里最重要的一条**：锁屏那一行绝不能带明文。
     *
     * 决定三（免解锁批准）之下，任何拿起手机的人都看得到这一行；一旦明文漏进来，
     * 等于把要发出去的内容公开在锁屏上。这条判据必须被用例钉住，不能只靠人跑一次真机看一眼。
     */
    @Test
    fun `lock screen line never carries the plaintext preview`() {
        val line = ConfirmNotificationContent.publicLine(
            RiskTier.RETRACTABLE, "发送消息", "文件传输助手",
        )

        assertEquals("可撤回 · 发送消息 → 文件传输助手", line)
        assertFalse("锁屏行不得出现明文预览", line.contains(preview))
        assertFalse("锁屏行不得出现摘要", line.contains("sha"))
    }

    /** 档位排第一：用户在锁屏上第一眼要判断的是"要不要立刻展开"。 */
    @Test
    fun `lock screen line leads with the risk tier`() {
        val irreversible = ConfirmNotificationContent.publicLine(
            RiskTier.IRREVERSIBLE, "click 危险目标", "支付宝",
        )

        assertTrue(irreversible.startsWith("不可逆 · "))
        assertTrue(
            ConfirmNotificationContent.publicLine(RiskTier.RETRACTABLE, "发送消息", "张三")
                .startsWith("可撤回 · ")
        )
    }

    @Test
    fun `lock screen line degrades safely on blank fields`() {
        val line = ConfirmNotificationContent.publicLine(RiskTier.IRREVERSIBLE, "", "")

        assertEquals("不可逆 · 危险动作 → 未知目标", line)
    }

    /** 展开态正好三项锚点：档位 + 目标会话 + 明文预览。多一项少一项都要有人重新想一遍。 */
    @Test
    fun `expanded text carries exactly the three anchors`() {
        val text = ConfirmNotificationContent.expandedText(
            RiskTier.RETRACTABLE, "文件传输助手", preview,
        )

        val lines = text.split("\n")
        assertEquals(3, lines.size)
        assertTrue(lines[0].startsWith("风险档位："))
        assertEquals("目标会话：文件传输助手", lines[1])
        assertEquals("实际输入预览：$preview", lines[2])
        // 明确不在里面的两项：前台包与"目标会话"冗余；输入长度只多说一句"还剩多少"。
        assertFalse(text.contains("前台"))
        assertFalse(text.contains("输入长度"))
        assertFalse(text.contains("SHA-256"))
    }

    @Test
    fun `expanded text says so when there is no input at all`() {
        val text = ConfirmNotificationContent.expandedText(RiskTier.IRREVERSIBLE, "支付宝", null)

        assertTrue(text.contains("本次动作没有输入内容"))
    }

    /**
     * II 级**不编造撤回时长**：撤回窗口由目标 App 定，网关无从得知。
     * 这与自举身份不许编造 activity 是同一条规矩——确认卡上不放没有依据的数字。
     */
    @Test
    fun `retract window is only claimed where it is actually known`() {
        assertTrue(
            ConfirmNotificationContent.tierDetail(RiskTier.RETRACTABLE, "com.tencent.mm")
                .contains("微信约 2 分钟")
        )
        val unknownApp = ConfirmNotificationContent.tierDetail(RiskTier.RETRACTABLE, "com.example.app")
        assertTrue(unknownApp.contains("以该 App 规则为准"))
        assertFalse("不得给未知 App 编一个时长", unknownApp.contains("分钟"))
    }

    @Test
    fun `irreversible tier says it plainly`() {
        val detail = ConfirmNotificationContent.tierDetail(RiskTier.IRREVERSIBLE, "com.tencent.mm")

        assertTrue(detail.contains("不可撤销"))
        assertFalse("I 级不得出现撤回窗口字样", detail.contains("撤回窗口"))
    }
}
