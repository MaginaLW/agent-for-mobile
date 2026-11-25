package dev.magina.gateway.a11y

import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.GatewayError
import dev.magina.gateway.core.Level
import dev.magina.gateway.core.RiskTier
import dev.magina.gateway.core.SafetyContext
import dev.magina.gateway.core.SafetyDecision
import dev.magina.gateway.core.SafetyGate
import dev.magina.gateway.core.SafetyPolicy
import dev.magina.gateway.core.SafetyTarget
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class SubtreeLabelPolicyTest {

    private fun clickArgs() = JSONObject()
        .put("action", "click")
        .put("ref", "e1")

    private fun contextWithLabel(label: String) = SafetyContext(
        packageName = "com.xingin.xhs",
        activityName = ".MainActivity",
        revision = 10L,
        target = SafetyTarget(
            ref = "e1",
            text = label,
            description = "",
            bounds = "[0,0][200,80]",
            source = "a11y",
        ),
    )

    @Test
    fun `aggregates visible non-interactive descendant text and desc for clickable container`() {
        val container = SubtreeLabelNode(
            isClickable = true,
            children = listOf(
                SubtreeLabelNode(desc = "购物车"),
                SubtreeLabelNode(
                    children = listOf(
                        SubtreeLabelNode(text = "  3  "),
                        SubtreeLabelNode(text = "购物车"), // 与前文重复不回声
                    ),
                ),
            ),
        )
        assertEquals("购物车 3", SubtreeLabelPolicy.aggregate(container))

        val longClickable = SubtreeLabelNode(
            isLongClickable = true,
            children = listOf(SubtreeLabelNode(text = "长按菜单")),
        )
        assertEquals("长按菜单", SubtreeLabelPolicy.aggregate(longClickable))
    }

    @Test
    fun `pure icon without descendant text or desc remains empty`() {
        val pureIcon = SubtreeLabelNode(
            isClickable = true,
            children = listOf(
                SubtreeLabelNode(),
                SubtreeLabelNode(children = listOf(SubtreeLabelNode())),
            ),
        )
        assertEquals("", SubtreeLabelPolicy.aggregate(pureIcon))
        assertEquals("", SubtreeLabelPolicy.aggregate(SubtreeLabelNode(isClickable = true)))
    }

    @Test
    fun `never borrows text from sibling nodes`() {
        val pureIcon = SubtreeLabelNode(isClickable = true)
        val siblingText = SubtreeLabelNode(text = "发送")
        // 父容器本身不可点击，仅作为包裹两个兄弟节点的布局容器
        val parent = SubtreeLabelNode(
            isClickable = false,
            children = listOf(pureIcon, siblingText),
        )

        assertEquals("", SubtreeLabelPolicy.aggregate(parent))
        assertEquals("", SubtreeLabelPolicy.aggregate(pureIcon))
    }

    @Test
    fun `rejects aggregation when container already has own text or desc or is editable or non-clickable`() {
        val hasOwnText = SubtreeLabelNode(
            isClickable = true,
            text = "关闭",
            children = listOf(SubtreeLabelNode(text = "子文本")),
        )
        val hasOwnDesc = SubtreeLabelNode(
            isClickable = true,
            desc = "关闭",
            children = listOf(SubtreeLabelNode(text = "子文本")),
        )
        val editable = SubtreeLabelNode(
            isClickable = true,
            isEditable = true,
            children = listOf(SubtreeLabelNode(text = "子文本")),
        )
        val nonClickable = SubtreeLabelNode(
            isClickable = false,
            children = listOf(SubtreeLabelNode(text = "子文本")),
        )
        val invisible = SubtreeLabelNode(
            isClickable = true,
            isVisibleToUser = false,
            children = listOf(SubtreeLabelNode(text = "子文本")),
        )

        assertEquals("", SubtreeLabelPolicy.aggregate(hasOwnText))
        assertEquals("", SubtreeLabelPolicy.aggregate(hasOwnDesc))
        assertEquals("", SubtreeLabelPolicy.aggregate(editable))
        assertEquals("", SubtreeLabelPolicy.aggregate(nonClickable))
        assertEquals("", SubtreeLabelPolicy.aggregate(invisible))
    }

    @Test
    fun `rejects aggregation when subtree contains nested interactive child like or favorite button`() {
        val withClickableLike = SubtreeLabelNode(
            isClickable = true,
            children = listOf(
                SubtreeLabelNode(text = "好物推荐笔记"),
                SubtreeLabelNode(isClickable = true, desc = "点赞"),
            ),
        )
        val withLongClickableFav = SubtreeLabelNode(
            isClickable = true,
            children = listOf(
                SubtreeLabelNode(text = "笔记标题"),
                SubtreeLabelNode(isLongClickable = true, desc = "收藏"),
            ),
        )
        val withCheckable = SubtreeLabelNode(
            isClickable = true,
            children = listOf(
                SubtreeLabelNode(text = "勾选条款"),
                SubtreeLabelNode(isCheckable = true),
            ),
        )
        val withEditable = SubtreeLabelNode(
            isClickable = true,
            children = listOf(
                SubtreeLabelNode(text = "搜索"),
                SubtreeLabelNode(isEditable = true),
            ),
        )
        val withDeepClickableAfterLongText = SubtreeLabelNode(
            isClickable = true,
            children = listOf(
                SubtreeLabelNode(text = "超长摘要文本".repeat(30)),
                SubtreeLabelNode(
                    children = listOf(
                        SubtreeLabelNode(isClickable = true, desc = "点赞"),
                    ),
                ),
            ),
        )

        assertEquals("", SubtreeLabelPolicy.aggregate(withClickableLike))
        assertEquals("", SubtreeLabelPolicy.aggregate(withLongClickableFav))
        assertEquals("", SubtreeLabelPolicy.aggregate(withCheckable))
        assertEquals("", SubtreeLabelPolicy.aggregate(withEditable))
        assertEquals("", SubtreeLabelPolicy.aggregate(withDeepClickableAfterLongText))
    }

    @Test
    fun `respects finite depth length and node scan cap`() {
        val deepText = SubtreeLabelNode(
            isClickable = true,
            children = listOf(
                SubtreeLabelNode(
                    children = listOf(
                        SubtreeLabelNode(text = "第二层"),
                        SubtreeLabelNode(
                            children = listOf(SubtreeLabelNode(text = "第三层")),
                        ),
                    ),
                ),
            ),
        )
        assertEquals("第二层", SubtreeLabelPolicy.aggregate(deepText, maxDepth = 2))
        assertEquals("第二层 第三层", SubtreeLabelPolicy.aggregate(deepText, maxDepth = 3))

        val longText = SubtreeLabelNode(
            isClickable = true,
            children = listOf(SubtreeLabelNode(text = "一二三四五六七八九十")),
        )
        assertEquals("一二三四五", SubtreeLabelPolicy.aggregate(longText, maxLength = 5))

        val oversized = SubtreeLabelNode(
            isClickable = true,
            children = (1..10).map { SubtreeLabelNode(text = "项$it") },
        )
        assertEquals("", SubtreeLabelPolicy.aggregate(oversized, maxScanNodes = 5))
    }

    @Test
    fun `ignores invisible descendants when collecting text`() {
        val container = SubtreeLabelNode(
            isClickable = true,
            children = listOf(
                SubtreeLabelNode(isVisibleToUser = false, text = "隐藏文案", children = listOf(SubtreeLabelNode(text = "深层隐藏"))),
                SubtreeLabelNode(isVisibleToUser = true, text = "可见文案"),
            ),
        )
        assertEquals("可见文案", SubtreeLabelPolicy.aggregate(container))
    }

    @Test
    fun `safety integration keeps pure icon and nested-interactive container in confirmation flow`() {
        val policy = SafetyPolicy()
        val pureIcon = SubtreeLabelNode(isClickable = true)
        val nestedInteractive = SubtreeLabelNode(
            isClickable = true,
            children = listOf(
                SubtreeLabelNode(text = "普通商品"),
                SubtreeLabelNode(isClickable = true, desc = "收藏"),
            ),
        )

        listOf(pureIcon, nestedInteractive).forEach { node ->
            val label = SubtreeLabelPolicy.aggregate(node)
            assertEquals("", label)
            val decision = policy.assess("ui_action", Level.W, clickArgs(), contextWithLabel(label))
            assertTrue(decision is SafetyDecision.ConfirmationRequired)
            assertEquals(RiskTier.IRREVERSIBLE, (decision as SafetyDecision.ConfirmationRequired).riskTier)

            var executorCalls = 0
            val gate = SafetyGate(
                policy = policy,
                confirmer = { false },
                contextProvider = { contextWithLabel(label) },
                onExecutionFailure = {},
            )
            try {
                gate.execute("ui_action", Level.W, clickArgs()) { _, _ ->
                    executorCalls += 1
                    JSONObject()
                }
                fail("expected E_BLOCKED when confirmation rejected")
            } catch (error: GatewayError) {
                assertEquals(ErrorCode.E_BLOCKED, error.code)
            }
            assertEquals(0, executorCalls)
        }
    }

    @Test
    fun `safety integration blocks or confirms when aggregated subtree label hits danger or sensitive words`() {
        val dangerNode = SubtreeLabelNode(
            isClickable = true,
            children = listOf(
                SubtreeLabelNode(text = "账户管理"),
                SubtreeLabelNode(text = "删除"),
            ),
        )
        val dangerLabel = SubtreeLabelPolicy.aggregate(dangerNode)
        assertEquals("账户管理 删除", dangerLabel)

        val policy = SafetyPolicy(sensitiveTargets = listOf("机密联系人"))
        val dangerDecision = policy.assess("ui_action", Level.W, clickArgs(), contextWithLabel(dangerLabel))
        assertTrue(dangerDecision is SafetyDecision.ConfirmationRequired)
        dangerDecision as SafetyDecision.ConfirmationRequired
        assertEquals(RiskTier.IRREVERSIBLE, dangerDecision.riskTier)
        assertTrue(dangerDecision.actionSummary.contains("删除"))

        var confirmPrompts = 0
        var executed = 0
        val rejectGate = SafetyGate(
            policy = policy,
            confirmer = {
                confirmPrompts += 1
                false
            },
            contextProvider = { contextWithLabel(dangerLabel) },
            onExecutionFailure = {},
        )
        try {
            rejectGate.execute("ui_action", Level.W, clickArgs()) { _, _ ->
                executed += 1
                JSONObject()
            }
            fail("expected E_BLOCKED")
        } catch (error: GatewayError) {
            assertEquals(ErrorCode.E_BLOCKED, error.code)
        }
        assertEquals(1, confirmPrompts)
        assertEquals(0, executed)

        // II 级发送词同样走确认
        val sendNode = SubtreeLabelNode(
            isClickable = true,
            children = listOf(SubtreeLabelNode(desc = "立即发送")),
        )
        val sendLabel = SubtreeLabelPolicy.aggregate(sendNode)
        val sendDecision = policy.assess("ui_action", Level.W, clickArgs(), contextWithLabel(sendLabel))
        assertTrue(sendDecision is SafetyDecision.ConfirmationRequired)
        assertEquals(RiskTier.RETRACTABLE, (sendDecision as SafetyDecision.ConfirmationRequired).riskTier)

        // 敏感词黑名单直接 E_BLOCKED
        val sensitiveNode = SubtreeLabelNode(
            isClickable = true,
            children = listOf(SubtreeLabelNode(text = "联系 机密联系人")),
        )
        val sensitiveLabel = SubtreeLabelPolicy.aggregate(sensitiveNode)
        val blockedDecision = policy.assess("ui_action", Level.W, clickArgs(), contextWithLabel(sensitiveLabel))
        assertTrue(blockedDecision is SafetyDecision.Blocked)
        assertEquals(ErrorCode.E_BLOCKED, (blockedDecision as SafetyDecision.Blocked).code)

        // 普通安全聚合标签可放行
        val safeNode = SubtreeLabelNode(
            isClickable = true,
            children = listOf(SubtreeLabelNode(text = "文件传输助手")),
        )
        val safeLabel = SubtreeLabelPolicy.aggregate(safeNode)
        assertEquals("文件传输助手", safeLabel)
        assertTrue(policy.assess("ui_action", Level.W, clickArgs(), contextWithLabel(safeLabel)) is SafetyDecision.Allowed)
    }
}
