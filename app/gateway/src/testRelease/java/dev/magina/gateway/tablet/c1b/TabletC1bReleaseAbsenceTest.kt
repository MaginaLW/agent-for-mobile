package dev.magina.gateway.tablet.c1b

import dev.magina.gateway.BuildConfig
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class TabletC1bReleaseAbsenceTest {
    @Test
    fun releaseKeepsReadOnlyProducerButNoDebugRuntimeClassesOrBuildBinding() {
        assertTrue(Class.forName("dev.magina.gateway.tablet.c1b.TabletC1bProbe") != null)
        val projectDir = File(requireNotNull(System.getProperty("user.dir")))
        val classNames = debugC1bClassNames(projectDir)
        assertTrue(classNames.contains("$C1B_PACKAGE.TabletC1bContentProvider"))
        assertTrue(classNames.contains("$C1B_PACKAGE.TabletC1bReadCoordinator"))
        assertTrue(classNames.contains("$C1B_PACKAGE.TabletC1bProtocol"))
        classNames.forEach { className ->
            assertTrue("release unexpectedly contains $className", runCatching {
                Class.forName(className, false, javaClass.classLoader)
            }.isFailure)
        }
        assertTrue(BuildConfig::class.java.declaredFields.none {
            it.name == "TABLET_C1B_GIT_HEAD" || it.name == "TABLET_C1B_BUILD_CHALLENGE"
        })
    }

    @Test
    fun nonDebugSourceSetsContainNoDebugRuntimeSurface() {
        val projectDir = File(requireNotNull(System.getProperty("user.dir")))
        val forbidden = listOf(
            "TabletC1bContentProvider",
            "TabletC1bProtocol",
            "TabletC1bReadCoordinator",
            "TabletC1bRuntimeController",
            "C1bPendingStartRegistry",
            "TrustedRuntimeContextFactory",
            "TABLET_C1B_GIT_HEAD",
            "TABLET_C1B_BUILD_CHALLENGE",
        )
        listOf(File(projectDir, "src/main"), File(projectDir, "src/release")).forEach { root ->
            if (root.exists()) {
                root.walkTopDown().filter(File::isFile).forEach { file ->
                    val content = file.readBytes().toString(Charsets.ISO_8859_1)
                    forbidden.forEach { marker -> assertFalse("${file.absolutePath}: $marker", marker in content) }
                }
            }
        }
        assertFalse(File(projectDir, "src/main/AndroidManifest.xml").readText().contains(C1B_PACKAGE))
    }

    private fun debugC1bClassNames(projectDir: File): Set<String> {
        val root = File(projectDir, "src/debug/java/dev/magina/gateway/tablet/c1b")
        assertTrue("missing debug C1b runtime source directory", root.isDirectory)
        val sources = root.walkTopDown()
            .filter { it.isFile && it.extension.lowercase() in setOf("kt", "java", "aidl") }
            .toList()
        assertTrue(sources.isNotEmpty())
        return buildSet {
            sources.forEach { source ->
                val text = source.readText(Charsets.UTF_8)
                TOP_LEVEL_TYPE.findAll(text).forEach { match -> add("$C1B_PACKAGE.${match.groupValues[1]}") }
                if (source.extension.equals("kt", ignoreCase = true)) {
                    add("$C1B_PACKAGE.${source.nameWithoutExtension}Kt")
                }
            }
        }
    }

    private companion object {
        const val C1B_PACKAGE = "dev.magina.gateway.tablet.c1b"
        val TOP_LEVEL_TYPE = Regex(
            "(?m)^(?:(?:public|internal|private|protected|data|sealed|fun|enum|value|annotation|" +
                "open|abstract|final|expect|actual)\\s+)*(?:class|interface|object)\\s+" +
                "([A-Za-z_][A-Za-z0-9_]*)",
        )
    }
}
