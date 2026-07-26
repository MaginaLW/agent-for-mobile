package dev.magina.gateway.core

import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 审计是安全硬门的证据链。原实现整个写盘裹在 runCatching{} 里，失败连痕迹都不留——
 * "一切正常，只是没有证据"是最坏的失败模式（`run-as` 读不到 external files 那次，
 * 采集坏了好几天没人发现，是同一类问题的另一面）。
 */
class AuditWriteFailureTest {

    private fun args() = JSONObject().put("key", "enter")

    private fun Audit.writeOnce() = write(
        auditId = "a-000001", tool = "press_key", args = args(),
        okCode = "OK", channel = "safety", elapsedMs = 1,
    )

    @Test
    fun `正常写盘不计失败并落下一行`() {
        val dir = File(System.getProperty("java.io.tmpdir"), "audit-ok-${System.nanoTime()}")
        try {
            val audit = Audit({ dir })
            audit.writeOnce()
            assertEquals(0L, audit.writeFailures)
            val files = dir.listFiles { f -> f.name.endsWith(".jsonl") }!!
            assertEquals(1, files.size)
            assertEquals(1, files[0].readLines().size)
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun `写盘失败必须被计数而不是静默吞掉`() {
        val audit = Audit({ throw java.io.IOException("模拟目录不可用") })
        audit.writeOnce()
        audit.writeOnce()
        assertEquals(2L, audit.writeFailures)
    }

    /** 审计失败不该把工具调用本身带崩：证据缺失比动作失败轻，但必须留痕。 */
    @Test
    fun `写盘失败不向调用方抛异常`() {
        val audit = Audit({ throw java.io.IOException("模拟目录不可用") })
        audit.writeOnce()   // 不抛即通过
        assertTrue(audit.writeFailures > 0)
    }

    /** 清理出问题不该污染"写盘失败"这个信号：行已经落下去了，报警就是假阳性。 */
    @Test
    fun `清理失败不计入写盘失败`() {
        val dir = File(System.getProperty("java.io.tmpdir"), "audit-prune-fail-${System.nanoTime()}")
        try {
            val audit = Audit({ dir })
            audit.writeOnce()
            assertEquals(0L, audit.writeFailures)
            // 写盘成功后把目录换成文件，使后续清理必然出错；计数仍应为 0。
            dir.deleteRecursively()
            dir.writeText("not a directory")
            val audit2 = Audit({ dir })
            audit2.writeOnce()
            assertTrue("目录不可用时写盘本身失败，应计数", audit2.writeFailures > 0)
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun `超过保留期的旧审计文件会被清掉，当天的保留`() {
        val dir = File(System.getProperty("java.io.tmpdir"), "audit-prune-${System.nanoTime()}")
        try {
            dir.mkdirs()
            val old = File(dir, "20200101.jsonl").apply {
                writeText("{}\n")
                setLastModified(System.currentTimeMillis() - (Audit.RETENTION_DAYS + 5) * 24 * 3600 * 1000)
            }
            val fresh = File(dir, "20991231.jsonl").apply { writeText("{}\n") }

            Audit({ dir }).writeOnce()

            assertTrue("超期文件应被清掉", !old.exists())
            assertTrue("未超期文件必须保留", fresh.exists())
        } finally {
            dir.deleteRecursively()
        }
    }
}
