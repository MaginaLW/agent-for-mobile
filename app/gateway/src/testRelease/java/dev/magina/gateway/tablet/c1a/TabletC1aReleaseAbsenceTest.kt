package dev.magina.gateway.tablet.c1a

import dev.magina.gateway.BuildConfig
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class TabletC1aReleaseAbsenceTest {
    @Test
    fun `release classpath has no class declared by the debug C1a package`() {
        val projectDir = File(requireNotNull(System.getProperty("user.dir")))
        val classNames = debugC1aClassNames(projectDir)
        assertTrue(classNames.contains("dev.magina.gateway.tablet.c1a.C1aPendingStartRegistry"))
        assertTrue(classNames.contains("dev.magina.gateway.tablet.c1a.TabletC1aContentProvider"))
        assertTrue(classNames.contains("dev.magina.gateway.tablet.c1a.TabletC1aSessionMachine"))
        classNames.forEach { className ->
            assertTrue("release unexpectedly contains $className", runCatching {
                Class.forName(className, false, javaClass.classLoader)
            }.isFailure)
        }
        assertTrue(BuildConfig::class.java.declaredFields.none { it.name.startsWith("TABLET_C1A_") })
    }

    private fun debugC1aClassNames(projectDir: File): Set<String> {
        val root = File(projectDir, "src/debug/java/dev/magina/gateway/tablet/c1a")
        assertTrue("missing debug C1a runtime source directory", root.isDirectory)
        val sources = root.walkTopDown()
            .filter { it.isFile && it.extension.lowercase() in setOf("kt", "java", "aidl") }
            .toList()
        assertTrue("debug C1a runtime source directory is empty", sources.isNotEmpty())
        return buildSet {
            sources.forEach { source ->
                val text = source.readText(Charsets.UTF_8)
                TOP_LEVEL_TYPE.findAll(text).forEach { match ->
                    add("$C1A_PACKAGE.${match.groupValues[1]}")
                }
                if (source.extension.equals("kt", ignoreCase = true)) {
                    add("$C1A_PACKAGE.${source.nameWithoutExtension}Kt")
                }
                if (source.extension.equals("aidl", ignoreCase = true)) {
                    add("$C1A_PACKAGE.${source.nameWithoutExtension}")
                }
            }
        }
    }

    @Test
    fun `non debug source sets contain no provider authority`() {
        val projectDir = File(requireNotNull(System.getProperty("user.dir")))
        listOf(File(projectDir, "src/main"), File(projectDir, "src/release")).forEach { root ->
            if (root.exists()) {
                root.walkTopDown().filter(File::isFile).forEach { file ->
                    val content = file.readBytes().toString(Charsets.ISO_8859_1)
                    assertFalse(file.absolutePath, content.contains("dev.magina.gateway.tablet.c1a"))
                    assertFalse(file.absolutePath, content.contains("TabletC1aContentProvider"))
                }
            }
        }
    }

    private companion object {
        const val C1A_PACKAGE = "dev.magina.gateway.tablet.c1a"
        val TOP_LEVEL_TYPE = Regex(
            "(?m)^(?:(?:public|internal|private|protected|data|sealed|fun|enum|value|annotation|" +
                "open|abstract|final|expect|actual)\\s+)*(?:class|interface|object)\\s+" +
                "([A-Za-z_][A-Za-z0-9_]*)",
        )
    }
}
