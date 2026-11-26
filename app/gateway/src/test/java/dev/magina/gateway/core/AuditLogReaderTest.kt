package dev.magina.gateway.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class AuditLogReaderTest {

    private fun withTempDir(block: (File) -> Unit) {
        val dir = File(System.getProperty("java.io.tmpdir"), "audit-reader-${System.nanoTime()}")
        try {
            dir.mkdirs()
            block(dir)
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun `missing or empty directory returns empty page safely`() {
        val missing = File(System.getProperty("java.io.tmpdir"), "audit-missing-${System.nanoTime()}")
        val pageMissing = AuditLogReader.readDay(missing)
        assertNull(pageMissing.dayKey)
        assertTrue(pageMissing.availableDays.isEmpty())
        assertNull(pageMissing.summary)
        assertTrue(pageMissing.records.isEmpty())

        withTempDir { empty ->
            File(empty, "notes.txt").writeText("ignored\n")
            val pageEmpty = AuditLogReader.readDay(empty)
            assertNull(pageEmpty.dayKey)
            assertTrue(pageEmpty.availableDays.isEmpty())
            assertTrue(pageEmpty.records.isEmpty())
        }
    }

    @Test
    fun `listDays filters non-date files and sorts descending`() {
        withTempDir { dir ->
            File(dir, "20261124.jsonl").writeText("{}\n")
            File(dir, "20261126.jsonl").writeText("{}\n")
            File(dir, "20261125.jsonl").writeText("{}\n")
            File(dir, "backup-20261126.jsonl").writeText("{}\n")
            File(dir, "20261126.txt").writeText("{}\n")
            File(dir, "20261127.jsonl").mkdirs()

            assertEquals(listOf("20261126", "20261125", "20261124"), AuditLogReader.listDays(dir))
        }
    }

    @Test
    fun `readDay parses filters summarizes and tolerates malformed lines`() {
        withTempDir { dir ->
            val file = File(dir, "20261126.jsonl")
            val secret = "高度机密测试内容-9182"
            val lines = listOf(
                buildAuditLine(
                    timestamp = "2026-11-26T10:00:01.000",
                    auditId = "a-000001",
                    tool = "device_info",
                    args = JSONObject(),
                    okCode = "OK",
                    channel = "api",
                    elapsedMs = 15,
                    note = "",
                ).toString(),
                "{broken-json-line",
                buildAuditLine(
                    timestamp = "2026-11-26T10:00:02.000",
                    auditId = "a-000002",
                    tool = "ui_find",
                    args = JSONObject().put("text", "我的淘宝"),
                    okCode = "E_NOT_FOUND",
                    channel = "a11y",
                    elapsedMs = 210,
                    note = "origin=macro",
                ).toString(),
                buildAuditLine(
                    timestamp = "2026-11-26T10:00:03.000",
                    auditId = "a-000003",
                    tool = "type_text",
                    args = JSONObject().put("text", secret).put("mode", "replace"),
                    okCode = "OK",
                    channel = "a11y",
                    elapsedMs = 340,
                    note = "",
                ).toString(),
                buildAuditLine(
                    timestamp = "2026-11-26T10:00:04.000",
                    auditId = "a-000004",
                    tool = "press_key",
                    args = JSONObject().put("key", "enter"),
                    okCode = "E_BLOCKED",
                    channel = "overlay",
                    elapsedMs = 5200,
                    note = "risk=confirmation_required;confirmation=denied;decided_via=overlay",
                ).toString(),
            )
            file.writeText(lines.joinToString("\n") + "\n")

            val allPage = AuditLogReader.readDay(dir, filter = AuditFilter.ALL)
            assertEquals("20261126", allPage.dayKey)
            val summary = allPage.summary!!
            assertEquals(4, summary.totalCount)
            assertEquals(2, summary.okCount)
            assertEquals(2, summary.failureCount)
            assertEquals(1, summary.safetyCount)
            assertEquals(1, summary.macroCount)
            assertEquals(1, summary.malformedLines)
            assertEquals(listOf("a-000004", "a-000003", "a-000002", "a-000001"), allPage.records.map { it.id })

            // 防御性脱敏：即使历史/异常记录含 text 字段，展示摘要也绝不透出明文。
            val typeRecord = allPage.records.first { it.id == "a-000003" }
            assertTrue(!typeRecord.argsSummary.contains(secret))
            assertTrue(typeRecord.argsSummary.contains("text=<redacted:${secret.length}>"))

            assertEquals(
                listOf("a-000004", "a-000002"),
                AuditLogReader.readDay(dir, filter = AuditFilter.FAILURES).records.map { it.id },
            )
            assertEquals(
                listOf("a-000004"),
                AuditLogReader.readDay(dir, filter = AuditFilter.SAFETY).records.map { it.id },
            )
            assertEquals(
                listOf("a-000002"),
                AuditLogReader.readDay(dir, filter = AuditFilter.MACRO).records.map { it.id },
            )
            assertEquals(
                listOf("a-000004", "a-000003"),
                AuditLogReader.readDay(dir, filter = AuditFilter.ALL, limit = 2).records.map { it.id },
            )
        }
    }

    @Test
    fun `oversized log file reads bounded tail safely`() {
        withTempDir { dir ->
            val file = File(dir, "20261126.jsonl")
            val padding = "x".repeat(400)
            val sb = StringBuilder()
            // 超过 MAX_READ_BYTES (1 MiB) 以触发尾部切片逻辑
            for (i in 1..2800) {
                sb.append(
                    buildAuditLine(
                        timestamp = "2026-11-26T10:00:00.000",
                        auditId = "a-%06d".format(i),
                        tool = "ui_snapshot",
                        args = JSONObject().put("pad", padding),
                        okCode = "OK",
                        channel = "a11y",
                        elapsedMs = 10,
                        note = "",
                    ).toString(),
                ).append('\n')
            }
            file.writeText(sb.toString())
            assertTrue(file.length() > AuditLogReader.MAX_READ_BYTES)

            val page = AuditLogReader.readDay(dir, limit = 5)
            assertEquals("a-002800", page.records.first().id)
            assertEquals(5, page.records.size)
            assertEquals(0, page.summary!!.malformedLines)
        }
    }
}
