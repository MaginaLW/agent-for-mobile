package dev.magina.gateway.a11y

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 会话页识别下沉到 `src/main` 之后的离线用例（spec §9.6 / backlog §8）。
 *
 * 下沉的全部意义是**只有一份判据**：宏（大脑侧）与执行前重建（网关内部）调的是同一个对象。
 * 所以这里既钉几何/门槛/宽松匹配这些规则本身，也钉"两个入口给出的是同一个结论"。
 *
 * **这个文件在 `src/test`，两个变体都会跑**——`testReleaseUnitTest` 能跑通它，就是
 * "标题识别在 release 构建里也在"的机械证据。backlog §8 那条退路（debug-only + 显式断言 +
 * 一条钉住 release 恒为 Unverified 的用例）因此不需要了：下沉真的做成了。
 */
class ConversationSurfacePolicyTest {

    private val screenWidth = 1260
    private val screenHeight = 2800

    /** 默认无状态栏：几何相关的老用例一个数都不该被新增的那一刀改掉。 */
    private val frame = SurfaceFrame(screenWidth, screenHeight, systemTopInset = 0)
    private val zeroFrame = SurfaceFrame(0, 0, systemTopInset = 0)

    private fun element(
        text: String = "文件传输助手",
        source: String = "ocr",
        confidence: Double? = 0.55,
        centerX: Int = screenWidth / 2,
        centerY: Int = (screenHeight * 0.06).toInt(),
        role: String = "text",
        // 有节点的元素默认按"来自前台应用窗口"造：老用例验的是置信度与几何，
        // 不该被 2026-08-09 新增的窗口归属那一道顺手改掉语义。
        foregroundWindow: Boolean = true,
    ): SurfaceElement {
        val bounds = SurfaceRect(centerX - 200, centerY - 30, centerX + 200, centerY + 30)
        return SurfaceElement(
            ref = "e1",
            role = role,
            text = text,
            description = "",
            bounds = bounds,
            source = source,
            confidence = confidence,
            stage = ConversationSurfacePolicy.stageOf(role, text, centerY, screenHeight),
            windowId = if (foregroundWindow) 7 else 99,
            foregroundWindow = foregroundWindow,
        )
    }

    // —— stage 划分（判据挂在它上面，所以它先得对） ——

    @Test
    fun `stage classification follows the bands the macro has always used`() {
        assertEquals(
            SurfaceStage.TOOLBAR,
            ConversationSurfacePolicy.stageOf("text", "文件传输助手", (screenHeight * 0.06).toInt(), screenHeight),
        )
        assertEquals(
            SurfaceStage.BOTTOM_INPUT,
            ConversationSurfacePolicy.stageOf("input", "", (screenHeight * 0.9).toInt(), screenHeight),
        )
        assertEquals(
            SurfaceStage.CONTENT,
            ConversationSurfacePolicy.stageOf("text", "随便", (screenHeight * 0.5).toInt(), screenHeight),
        )
        // 顶部的输入框与「搜索」「取消」优先归 SEARCH，压过标题带
        assertEquals(
            SurfaceStage.SEARCH,
            ConversationSurfacePolicy.stageOf("input", "", (screenHeight * 0.06).toInt(), screenHeight),
        )
        assertEquals(
            SurfaceStage.SEARCH,
            ConversationSurfacePolicy.stageOf("text", "搜 索", (screenHeight * 0.06).toInt(), screenHeight),
        )
    }

    // —— 识别门槛与几何 ——

    @Test
    fun `recognition accepts ocr confidence below the action threshold`() {
        // 2026-07-23 真机实锤：页面级标题置信度落在 0.5~0.65，过不了点击级门槛。
        // 识别级门槛存在的全部理由就是这个，别把它调回去。
        assertTrue(MIN_RECOGNITION_OCR_CONFIDENCE < MIN_ACTION_OCR_CONFIDENCE)
        assertNotNull(
            ConversationSurfacePolicy.conversationTitle(
                listOf(element(confidence = 0.55)), frame, "文件传输助手",
            ),
        )
    }

    @Test
    fun `recognition rejects ocr below the recognition threshold`() {
        assertNull(
            ConversationSurfacePolicy.conversationTitle(
                listOf(element(confidence = 0.30)), frame, "文件传输助手",
            ),
        )
    }

    @Test
    fun `recognition rejects text outside the title band`() {
        val tooLow = element(centerY = (screenHeight * 0.5).toInt())
        val offCenter = element(centerX = (screenWidth * 0.1).toInt())
        assertNull(
            ConversationSurfacePolicy.conversationTitle(listOf(tooLow), frame, "文件传输助手"),
        )
        assertNull(
            ConversationSurfacePolicy.conversationTitle(listOf(offCenter), frame, "文件传输助手"),
        )
    }

    @Test
    fun `recognition rejects bounds that fall outside the screen`() {
        val broken = element().let {
            it.copy(bounds = SurfaceRect(-1, it.bounds.top, it.bounds.right, it.bounds.bottom))
        }
        assertNull(
            ConversationSurfacePolicy.conversationTitle(listOf(broken), frame, "文件传输助手"),
        )
    }

    @Test
    fun `zero sized screen recognizes nothing instead of dividing by it`() {
        assertNull(ConversationSurfacePolicy.conversationTitle(listOf(element()), zeroFrame, "文件传输助手"))
        assertNull(ConversationSurfacePolicy.toolbarTitle(listOf(element()), zeroFrame))
    }

    // —— 宽松匹配：这是宏那条真机实锤的规则，下沉之后一字未改 ——

    @Test
    fun `ocr noise on the tail still recognizes the conversation`() {
        assertNotNull(
            ConversationSurfacePolicy.conversationTitle(
                listOf(element(text = "文件传输助手8")), frame, "文件传输助手",
            ),
        )
    }

    @Test
    fun `another conversation is not recognized as the expected one`() {
        assertNull(
            ConversationSurfacePolicy.conversationTitle(
                listOf(element(text = "微信")), frame, "文件传输助手",
            ),
        )
    }

    // —— 两个入口一份判据 ——

    @Test
    fun `toolbarTitle reads whatever is on the band without judging it`() {
        // 生产侧要的正是这个：先拿到"标题带上到底写着什么"，再由 EvidenceRebuildPolicy 去比。
        // 把比对塞进读取器，判据就变成"读回来的和读回来的一样"（发送后验踩过这个坑）。
        val other = element(text = "微信")
        val read = ConversationSurfacePolicy.toolbarTitle(listOf(other), frame)
        assertEquals("微信", read?.text)
    }

    @Test
    fun `both entries agree because they share one implementation`() {
        val elements = listOf(element(text = "文件传输助手8"))
        val recognized =
            ConversationSurfacePolicy.conversationTitle(elements, frame, "文件传输助手")
        val read = ConversationSurfacePolicy.toolbarTitle(elements, frame)
        assertEquals(read, recognized)
        assertTrue(
            ConversationSurfacePolicy.isConversationSurface(
                elements, frame, "文件传输助手",
            ),
        )
    }

    @Test
    fun `an untrusted element is invisible to both entries alike`() {
        val elements = listOf(element(confidence = 0.10))
        assertNull(ConversationSurfacePolicy.toolbarTitle(elements, frame))
        assertNull(
            ConversationSurfacePolicy.conversationTitle(elements, frame, "文件传输助手"),
        )
    }

    // —— JSON 解码：宏与生产解的是同一个 snapshot ——

    @Test
    fun `decode maps snapshot json into elements with stages`() {
        val raw = JSONObject().put(
            "elements",
            JSONArray()
                .put(
                    JSONObject()
                        .put("ref", "r1").put("role", "text").put("text", "文件传输助手")
                        .put("source", "ocr").put("confidence", 0.55)
                        .put("bounds", JSONArray(listOf(430, 138, 830, 198))),
                )
                // bounds 少一个数：跳过，不是造一个退化矩形
                .put(JSONObject().put("ref", "r2").put("bounds", JSONArray(listOf(1, 2, 3))))
                // 没有 bounds：跳过
                .put(JSONObject().put("ref", "r3").put("text", "无几何")),
        )
        val elements = ConversationSurfacePolicy.decodeElements(raw, screenHeight)
        assertEquals(1, elements.size)
        assertEquals(SurfaceStage.TOOLBAR, elements[0].stage)
        assertEquals(0.55, elements[0].confidence!!, 1e-9)
        assertNotNull(
            ConversationSurfacePolicy.conversationTitle(elements, frame, "文件传输助手"),
        )
    }

    @Test
    fun `decode of a snapshot without elements is empty rather than throwing`() {
        assertEquals(0, ConversationSurfacePolicy.decodeElements(JSONObject(), screenHeight).size)
    }

    // —— 状态栏不是会话标题（2026-08-09 第四跑，用户被诬告换了会话） ——
    //
    // 真机形态：这台 vivo 状态栏常驻实时网速，a11y **跨窗口**，于是 `7.70KB/s` 落进标题带、
    // 被当成标题读回，`E_STALE_REF`「目标会话与已批准的不符：文件传输助手 → 7.70KB/s」。
    // **用户全程没换过会话。** C 道点名：这形态用 fixture 就能造，根本不需要真机。

    /**
     * 状态栏那条实时网速：另一个窗口、贴着屏幕顶、文本每秒都在变。
     *
     * 默认 centerY=65 取自**实测**（C 道从截图量得 65~70px），而带的上沿是 2%×2800=56：
     * 状态栏文字**落在带内**，所以它一直是这条带的合法候选，昨晚被选中是运气不是回归。
     *
     * 这个数一开始我写成 55，而 55 落在**带外**——**那样它压根不该成为候选，也就解释不了
     * 昨晚为什么会被选中**。解释与它要解释的现象自相矛盾，就说明解释错了（复核清单已收）。
     */
    private fun statusBarSpeed(
        text: String = "7.70KB/s",
        centerY: Int = 65,
    ): SurfaceElement = element(
        text = text,
        source = "a11y",
        confidence = null,
        centerY = centerY,
        foregroundWindow = false,
    ).let { it.copy(bounds = SurfaceRect(it.bounds.left, centerY - 20, it.bounds.right, centerY + 20)) }

    @Test
    fun `a status bar element is never read as the conversation title`() {
        val elements = listOf(statusBarSpeed())
        assertNull(ConversationSurfacePolicy.toolbarTitle(elements, frame))
    }

    @Test
    fun `the status bar loses to the real title even when it comes first`() {
        // 顺序很要紧：`toolbarTitle` 取的是 firstOrNull，而状态栏窗口先于应用窗口被遍历。
        // 这一条钉的正是"排在前面也抢不走"。
        val elements = listOf(statusBarSpeed(), element(text = "文件传输助手"))
        assertEquals("文件传输助手", ConversationSurfacePolicy.toolbarTitle(elements, frame)?.text)
    }

    @Test
    fun `window ownership and the status bar cut are two independent gates`() {
        // ① 只有几何那一刀：网速被状态栏下沿挡住。
        val speedInsideBand = statusBarSpeed(centerY = 90).copy(foregroundWindow = true)
        assertNull(
            ConversationSurfacePolicy.toolbarTitle(
                listOf(speedInsideBand),
                frame.copy(systemTopInset = 120),
            ),
        )
        // ② 只有窗口那一刀：即使它落在状态栏之下（例如没量到 inset），窗口归属仍挡得住。
        assertNull(
            ConversationSurfacePolicy.toolbarTitle(
                listOf(statusBarSpeed(centerY = 200)),
                frame,
            ),
        )
    }

    @Test
    fun `pure ocr text keeps working because it has no window to belong to`() {
        // OCR 元素是屏幕像素，没有节点也就没有窗口。**窗口那一道对它必须不生效**，
        // 否则微信这条 OCR-only 链上标题永远读不回来——那是另一种形态的全面失效。
        val ocrTitle = element(text = "文件传输助手", source = "ocr", foregroundWindow = false)
        assertEquals("文件传输助手", ConversationSurfacePolicy.toolbarTitle(listOf(ocrTitle), frame)?.text)
        // 但它照样要在状态栏之下：OCR 也会把状态栏上的字识出来。
        val ocrSpeed = element(text = "0.10 KB/s", source = "ocr", foregroundWindow = false)
            .let { it.copy(bounds = SurfaceRect(it.bounds.left, 40, it.bounds.right, 80)) }
        assertNull(
            ConversationSurfacePolicy.toolbarTitle(listOf(ocrSpeed), frame.copy(systemTopInset = 120)),
        )
    }

    @Test
    fun `candidates say why each one lost, including the ones from other windows`() {
        // 第四跑现场"标题带把状态栏圈进去了"是**推断**——uiautomator dump 看不见状态栏。
        // 跨窗口的东西只有网关自己看得见，所以只能由它把清单打出来。
        val elements = listOf(statusBarSpeed(), element(text = "文件传输助手"), element(confidence = 0.10))
        val candidates = ConversationSurfacePolicy.titleBandCandidates(elements, frame)
        assertEquals(3, candidates.size)
        assertEquals(SurfaceCandidate.REJECT_WINDOW, candidates[0].rejectedBy)
        assertNull(candidates[1].rejectedBy)
        assertEquals(SurfaceCandidate.REJECT_CONFIDENCE, candidates[2].rejectedBy)
        // 那一行要能让人一眼看出它是谁：文本 + 几何 + 来源 + 窗口归属。
        val line = candidates[0].describe()
        assertTrue(line.contains("7.70KB/s"))
        assertTrue(line.contains("非前台应用"))
    }

    @Test
    fun `a cut element and an element that was never produced are different facts`() {
        // 2026-08-09 第五跑卡在这里：`band` 少一个时，"被状态栏那一刀切掉了"与
        // "这一帧压根没识出它"**在落盘证据上分不开**——而前者说明闸门在干活、
        // 后者说明闸门根本没被考到。**一条判据以"跑绿了"的姿态挂着却从没被考到**，
        // 正是本仓吃亏最多的形态。
        val cutFrame = frame.copy(systemTopInset = 120)
        val speedAbove = statusBarSpeed().copy(foregroundWindow = true)

        // ① 上面确实有东西，被切掉了。
        val cut = ConversationSurfacePolicy.topCutCandidates(listOf(speedAbove), cutFrame)
        assertEquals(1, cut.size)
        assertEquals(SurfaceCandidate.REJECT_TOP_CUT, cut[0].rejectedBy)
        // **它不在候选表里**：几何那一刀发生在候选枚举之前，所以两张表必须分开看。
        assertEquals(0, ConversationSurfacePolicy.titleBandCandidates(listOf(speedAbove), cutFrame).size)

        // ② 什么都没有：两张表都空。这才是"这一帧没产出它"。
        assertEquals(0, ConversationSurfacePolicy.topCutCandidates(emptyList(), cutFrame).size)
        assertEquals(0, ConversationSurfacePolicy.titleBandCandidates(emptyList(), cutFrame).size)
    }

    @Test
    fun `the real title is never counted as cut`() {
        // 切掉那一栏只能收"本来会是候选、只差状态栏这一刀"的元素。把正常标题也算进去，
        // 这一栏就会永远非零，于是它作为信号的价值当场归零（恒真判据同族）。
        val title = element(text = "文件传输助手")
        assertEquals(0, ConversationSurfacePolicy.topCutCandidates(listOf(title), frame.copy(systemTopInset = 40)).size)
    }

    @Test
    fun `a snapshot without the new fields keeps a11y elements out rather than trusting them`() {
        // 旧 APK 的快照没有 fg_window：缺字段一律按"不属于前台应用窗口"处理。
        // **方向必须是 fail-closed**——反过来就等于让旧快照冒充可信，而那正是今天这个伤害。
        val raw = JSONObject().put(
            "elements",
            JSONArray().put(
                JSONObject()
                    .put("ref", "r1").put("role", "text").put("text", "文件传输助手")
                    .put("source", "a11y")
                    .put("bounds", JSONArray(listOf(430, 138, 830, 198))),
            ),
        )
        val elements = ConversationSurfacePolicy.decodeElements(raw, screenHeight)
        assertEquals(1, elements.size)
        assertNull(elements[0].windowId)
        assertNull(ConversationSurfacePolicy.toolbarTitle(elements, frame))
    }

    @Test
    fun `decode carries window ownership through`() {
        val raw = JSONObject().put(
            "elements",
            JSONArray().put(
                JSONObject()
                    .put("ref", "r1").put("role", "text").put("text", "文件传输助手")
                    .put("source", "a11y").put("window_id", 12).put("fg_window", true)
                    .put("bounds", JSONArray(listOf(430, 138, 830, 198))),
            ),
        )
        val elements = ConversationSurfacePolicy.decodeElements(raw, screenHeight)
        assertEquals(12, elements[0].windowId)
        assertTrue(elements[0].foregroundWindow)
        assertNotNull(ConversationSurfacePolicy.toolbarTitle(elements, frame))
    }
}
