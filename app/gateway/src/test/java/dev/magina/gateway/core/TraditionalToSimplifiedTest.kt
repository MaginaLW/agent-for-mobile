package dev.magina.gateway.core

import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class TraditionalToSimplifiedTest {

    @Test
    fun `table length, strict UTF-16 order, non-identity, and full-table idempotence hold`() {
        val trad = TraditionalToSimplified.TRAD
        val simp = TraditionalToSimplified.SIMP

        assertEquals(2334, trad.size)
        assertEquals(trad.size, simp.size)

        for (i in trad.indices) {
            if (i > 0) {
                assertTrue(
                    "TRAD 必须按 UTF-16 严格升序：index=$i prev=${trad[i - 1]} cur=${trad[i]}",
                    trad[i - 1] < trad[i],
                )
            }
            assertTrue(
                "TRAD[$i] 不得自映射：${trad[i]}",
                trad[i] != simp[i],
            )
            // 全表幂等：fold(fold(c)) == fold(c)（即任何目标简体字都不在 TRAD 中）
            assertEquals(
                "映射必须幂等：${trad[i]} -> ${simp[i]}",
                simp[i],
                TraditionalToSimplified.foldChar(simp[i]),
            )
            val once = TraditionalToSimplified.fold(trad[i].toString())
            assertEquals(1, once.length)
            assertEquals(simp[i].toString(), once)
            assertEquals(once, TraditionalToSimplified.fold(once))
        }
    }

    @Test
    fun `fast path returns original string reference when no char folds and preserves zhu`() {
        val unchanged = listOf("", "PA2553-2026", "文件传输助手", "著作", "著", "发送", "删除", "确认")
        for (s in unchanged) {
            assertSame("无繁体字符应走零分配快路径：$s", s, TextNorm.foldTraditionalToSimplified(s))
        }
        assertFalse("U+8457(著) 不得进入繁→简表", TraditionalToSimplified.TRAD.contains('\u8457'))
    }

    @Test
    fun `all required traditional to simplified pairs and PA2553 live OCR samples fold cleanly`() {
        val requiredPairs = listOf(
            '輸' to '输', '橫' to '横', '發' to '发', '刪' to '删', '確' to '确', '認' to '认',
            '傳' to '传', '轉' to '转', '帳' to '帐', '賬' to '账', '購' to '购', '買' to '买',
            '註' to '注', '銷' to '销', '載' to '载', '碼' to '码', '權' to '权', '許' to '许',
            '結' to '结', '訂' to '订', '單' to '单', '裝' to '装', '廠' to '厂', '臺' to '台',
            '裡' to '里', '復' to '复', '評' to '评', '論' to '论',
        )
        for ((t, s) in requiredPairs) {
            assertEquals("映射 $t -> $s 失败", s, TraditionalToSimplified.foldChar(t))
        }

        // PA2553 真机实测 OCR 抖动样本（#178）
        assertEquals("文件传输助手", TextNorm.foldTraditionalToSimplified("文件传輸助手"))
        assertEquals(
            "PA2553横屏确认卡验收-20261122",
            TextNorm.foldTraditionalToSimplified("PA2553橫屏确认卡验收-20261122"),
        )
        assertEquals(TextNorm.ocr("文件传输助手"), TextNorm.ocr("文件传輸助手"))
        assertEquals(
            TextNorm.ocr("PA2553横屏确认卡验收-20261122"),
            TextNorm.ocr("PA2553橫屏确认卡验收-20261122"),
        )
    }

    @Test
    fun `all safety json keywords and SafetyPolicy default words remain strictly invariant`() {
        val safety = loadSafetyAsset()
        val assetWords = buildList {
            for (key in listOf("danger_words", "action_confirm_words", "send_words", "sensitive_targets")) {
                val arr = safety.getJSONArray(key)
                for (i in 0 until arr.length()) add(arr.getString(i))
            }
        }
        val policyWords = SafetyPolicy.DEFAULT_IRREVERSIBLE_WORDS +
            SafetyPolicy.DEFAULT_RETRACTABLE_WORDS +
            SafetyPolicy.DEFAULT_ACTION_CONFIRM_WORDS +
            listOf("密码", "收款", "风险", "警告")

        assertTrue("safety.json 词表不应为空", assetWords.isNotEmpty())
        for (word in (assetWords + policyWords).distinct()) {
            assertEquals(
                "安全词条「$word」在繁→简折叠下必须保持不变",
                word,
                TextNorm.foldTraditionalToSimplified(word),
            )
        }
    }

    private fun loadSafetyAsset(): JSONObject {
        val userDir = requireNotNull(System.getProperty("user.dir")) { "JVM 未提供 user.dir" }
        var cursor: File? = File(userDir).absoluteFile
        while (cursor != null) {
            val candidates = listOf(
                File(cursor, "gateway/src/main/assets/skillpack/safety.json"),
                File(cursor, "app/gateway/src/main/assets/skillpack/safety.json"),
            )
            candidates.firstOrNull(File::isFile)?.let { return JSONObject(it.readText()) }
            cursor = cursor.parentFile
        }
        error("找不到 skillpack/safety.json（user.dir=$userDir）")
    }
}
