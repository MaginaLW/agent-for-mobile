package dev.magina.gateway.tablet.c1a

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

class TabletC1aSurfaceTest {
    @Test
    fun `debug manifest exposes exactly one DUMP protected non grantable provider`() {
        val manifest = projectFile("src/debug/AndroidManifest.xml")
        val document = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
            .newDocumentBuilder().parse(manifest)
        val providers = document.getElementsByTagName("provider")
        assertEquals(1, providers.length)
        val provider = providers.item(0).attributes
        assertEquals(
            ".tablet.c1a.TabletC1aContentProvider",
            provider.getNamedItemNS(ANDROID_NAMESPACE, "name").nodeValue,
        )
        assertEquals(
            TABLET_C1A_AUTHORITY,
            provider.getNamedItemNS(ANDROID_NAMESPACE, "authorities").nodeValue,
        )
        assertEquals("true", provider.getNamedItemNS(ANDROID_NAMESPACE, "exported").nodeValue)
        assertEquals("false", provider.getNamedItemNS(ANDROID_NAMESPACE, "grantUriPermissions").nodeValue)
        assertEquals(
            "android.permission.DUMP",
            provider.getNamedItemNS(ANDROID_NAMESPACE, "permission").nodeValue,
        )
        assertFalse(projectFile("src/main/AndroidManifest.xml").readText().contains(TABLET_C1A_AUTHORITY))
    }

    @Test
    fun `provider has shell UID guard anonymous pipes and no action or persistence wiring`() {
        val providerSource = projectFile(
            "src/debug/java/dev/magina/gateway/tablet/c1a/TabletC1aContentProvider.kt",
        ).readText()
        val runtimeFiles = projectDirectory("src/debug/java/dev/magina/gateway/tablet/c1a")
            .walkTopDown()
            .filter(File::isFile)
            .toList()
        assertTrue("C1a runtime source set is unexpectedly empty", runtimeFiles.isNotEmpty())
        runtimeFiles.forEach { file ->
            assertTrue(
                "unknown C1a runtime source extension can bypass the closed scan: $file",
                file.extension.lowercase() in RUNTIME_SOURCE_EXTENSIONS,
            )
        }
        val runtimeSource = runtimeFiles.joinToString("\n") { it.readText(Charsets.UTF_8) }
        assertTrue(providerSource.contains("Binder.getCallingUid() != Process.SHELL_UID"))
        assertTrue(providerSource.contains("ParcelFileDescriptor.createPipe()"))
        assertTrue(providerSource.contains("supports openFile read/write streams only"))
        listOf("override fun call(", "override fun bulkInsert(", "override fun openTypedAssetFile(")
            .forEach { closedSurface ->
                assertTrue("missing closed surface: $closedSurface", providerSource.contains(closedSurface))
            }
        listOf(
            "GatewayService",
            "ToolRegistry",
            "McpServer",
            "MacroRunner",
            "MainActivity",
            "performAction",
            "dispatchGesture",
            "takeScreenshot",
            "Settings.",
            "startActivity",
            "sendBroadcast",
            "Thread.sleep",
            "java.net.Socket",
        ).forEach { forbidden ->
            assertFalse("forbidden C1a runtime surface: $forbidden", runtimeSource.contains(forbidden))
        }
        assertFalse(Regex("(?m)^import java\\.io\\.File$").containsMatchIn(runtimeSource))
    }

    private fun projectFile(relative: String): File = File(System.getProperty("user.dir"), relative).also {
        assertTrue("missing project file: $it", it.isFile)
    }

    private fun projectDirectory(relative: String): File = File(System.getProperty("user.dir"), relative).also {
        assertTrue("missing project directory: $it", it.isDirectory)
    }

    private companion object {
        const val ANDROID_NAMESPACE = "http://schemas.android.com/apk/res/android"
        val RUNTIME_SOURCE_EXTENSIONS = setOf("kt", "java", "xml", "aidl")
    }
}
