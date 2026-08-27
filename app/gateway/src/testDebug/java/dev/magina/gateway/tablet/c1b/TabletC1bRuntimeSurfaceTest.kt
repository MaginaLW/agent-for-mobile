package dev.magina.gateway.tablet.c1b

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

class TabletC1bRuntimeSurfaceTest {
    @Test
    fun debugManifestHasExactlyOneDumpProtectedC1bProvider() {
        val document = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
            .newDocumentBuilder().parse(projectFile("src/debug/AndroidManifest.xml"))
        val providers = document.getElementsByTagName("provider")
        val matches = (0 until providers.length).map { providers.item(it) }.filter { node ->
            node.attributes.getNamedItemNS(ANDROID_NAMESPACE, "authorities")?.nodeValue == TABLET_C1B_AUTHORITY
        }

        assertEquals(1, matches.size)
        val attributes = matches.single().attributes
        assertEquals(
            ".tablet.c1b.TabletC1bContentProvider",
            attributes.getNamedItemNS(ANDROID_NAMESPACE, "name").nodeValue,
        )
        assertEquals("true", attributes.getNamedItemNS(ANDROID_NAMESPACE, "exported").nodeValue)
        assertEquals("false", attributes.getNamedItemNS(ANDROID_NAMESPACE, "grantUriPermissions").nodeValue)
        assertEquals(
            "android.permission.DUMP",
            attributes.getNamedItemNS(ANDROID_NAMESPACE, "permission").nodeValue,
        )
        assertFalse(projectFile("src/main/AndroidManifest.xml").readText().contains(TABLET_C1B_AUTHORITY))
    }

    @Test
    fun providerIsShellOnlyAnonymousPipeAndCaptureEndpointOnlyQueuesDedicatedWorker() {
        val root = projectDirectory("src/debug/java/dev/magina/gateway/tablet/c1b")
        val sources = root.walkTopDown().filter(File::isFile).toList()
        assertTrue(sources.isNotEmpty())
        assertTrue(sources.all { it.extension.lowercase() in setOf("kt", "java", "aidl") })
        val runtime = sources.joinToString("\n") { it.readText(Charsets.UTF_8) }
        val provider = projectFile(
            "src/debug/java/dev/magina/gateway/tablet/c1b/TabletC1bContentProvider.kt",
        ).readText()

        assertTrue(provider.contains("Binder.getCallingUid() != Process.SHELL_UID"))
        assertTrue(provider.contains("ParcelFileDescriptor.createPipe()"))
        assertTrue(provider.contains("tablet-c1b-capture-worker"))
        assertTrue(provider.contains("Executors.newSingleThreadExecutor"))
        assertTrue(provider.contains("controller.capture(endpoint.key, endpoint.token)"))
        assertTrue(provider.contains("revisionProvider = { c1bCaptureRevision(service.revision, captureToken) }"))
        assertFalse(provider.contains("val frameRevision"))
        assertTrue(provider.contains("supports openFile read/write streams only"))
        listOf("override fun call(", "override fun bulkInsert(", "override fun openTypedAssetFile(")
            .forEach { surface -> assertTrue("missing closed surface $surface", provider.contains(surface)) }
        listOf(
            "performAction", "dispatchGesture", "takeScreenshot", "Settings.", "startActivity",
            "sendBroadcast", "Thread.sleep", "java.net.Socket", "OcrEngine", "Bitmap",
        ).forEach { forbidden ->
            assertFalse("forbidden C1b runtime surface: $forbidden", runtime.contains(forbidden))
        }
        assertFalse(Regex("(?m)^import java\\.io\\.File$").containsMatchIn(runtime))
    }

    @Test
    fun androidWrappersAndIdentityBoundaryAreExplicitlyRedactedAndHashFree() {
        val source = projectFile(
            "src/main/java/dev/magina/gateway/tablet/c1b/AndroidTabletC1bSource.kt",
        ).readText()
        val model = projectFile(
            "src/main/java/dev/magina/gateway/tablet/c1b/TabletC1bModel.kt",
        ).readText()

        assertTrue(source.contains("private class AndroidC1bWindow"))
        assertTrue(source.contains("private class AndroidC1bNode"))
        assertFalse(source.contains("private data class AndroidC1bWindow"))
        assertFalse(source.contains("private data class AndroidC1bNode"))
        assertTrue(source.contains("AndroidC1bWindow(value=<redacted>)"))
        assertTrue(source.contains("AndroidC1bNode(value=<redacted>)"))
        assertTrue(source.contains("nodesExactlyEqual"))
        assertFalse(source.contains("hashCode()"))
        assertTrue(model.contains("value class C1bNodeIdentityToken(val value: String)"))
    }

    @Test
    fun buildDefinesIndependentC1bBindingAndNarrowReleaseAbsenceGate() {
        val build = projectFile("build.gradle.kts").readText()
        assertTrue(build.contains("TL1_C1B_EXPECTED_COMMIT_SHA"))
        assertTrue(build.contains("TABLET_C1B_GIT_HEAD"))
        assertTrue(build.contains("TABLET_C1B_BUILD_CHALLENGE"))
        assertTrue(build.contains("verifyTabletC1bReleaseAbsence"))
        assertTrue(build.contains("main producer may remain") || build.contains("producer may remain"))
        assertFalse(build.contains("val c1bPackageDotPrefix"))
        assertFalse(build.contains("val c1bPackageSlashPrefix"))
    }

    private fun projectFile(relative: String): File = File(System.getProperty("user.dir"), relative).also {
        assertTrue("missing project file: $it", it.isFile)
    }

    private fun projectDirectory(relative: String): File = File(System.getProperty("user.dir"), relative).also {
        assertTrue("missing project directory: $it", it.isDirectory)
    }

    private companion object {
        const val ANDROID_NAMESPACE = "http://schemas.android.com/apk/res/android"
    }
}
