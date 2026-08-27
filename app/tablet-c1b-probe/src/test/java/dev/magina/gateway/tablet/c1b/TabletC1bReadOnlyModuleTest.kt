package dev.magina.gateway.tablet.c1b

import dev.magina.gateway.BuildConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

class TabletC1bReadOnlyModuleTest {
    @Test
    fun applicationIdentityAndBuildBindingAreExactInEveryVariant() {
        assertEquals(APPLICATION_ID, BuildConfig.APPLICATION_ID)
        assertTrue(BuildConfig.TABLET_C1B_GIT_HEAD.matches(Regex("[0-9a-f]{40}")))
        assertTrue(BuildConfig.TABLET_C1B_BUILD_CHALLENGE.matches(Regex("[a-z0-9][a-z0-9._-]{15,95}")))
        assertTrue(Class.forName(SERVICE_CLASS) != null)
        assertTrue(Class.forName(PROVIDER_CLASS) != null)
        assertTrue(Class.forName("dev.magina.gateway.tablet.c1b.TabletC1bProbe") != null)
    }

    @Test
    fun gatewayActionMcpScreenshotImeAndActivityClassesAreAbsent() {
        listOf(
            "dev.magina.gateway.Gateway",
            "dev.magina.gateway.GatewayService",
            "dev.magina.gateway.MainActivity",
            "dev.magina.gateway.ime.GatewayIme",
            "dev.magina.gateway.mcp.McpServer",
            "dev.magina.gateway.ocr.OcrEngine",
            "dev.magina.gateway.overlay.ConfirmOverlay",
            "dev.magina.gateway.tools.UiTools",
        ).forEach { forbidden ->
            assertTrue("dedicated C1b module unexpectedly contains $forbidden", runCatching {
                Class.forName(forbidden, false, javaClass.classLoader)
            }.isFailure)
        }
    }

    @Test
    fun sourceManifestAndAccessibilityConfigExposeOnlyTheClosedReadSurface() {
        val projectDir = File(requireNotNull(System.getProperty("user.dir")))
        val manifest = xml(File(projectDir, "src/main/AndroidManifest.xml"))
        assertEquals(0, manifest.getElementsByTagName("uses-permission").length)
        assertEquals(0, manifest.getElementsByTagName("activity").length)
        assertEquals(0, manifest.getElementsByTagName("activity-alias").length)
        assertEquals(0, manifest.getElementsByTagName("receiver").length)
        assertEquals(1, manifest.getElementsByTagName("service").length)
        assertEquals(1, manifest.getElementsByTagName("provider").length)

        val service = manifest.getElementsByTagName("service").item(0)
        assertEquals(".a11y.GatewayA11yService", service.attributes.getNamedItemNS(ANDROID_NS, "name").nodeValue)
        assertEquals(
            "android.permission.BIND_ACCESSIBILITY_SERVICE",
            service.attributes.getNamedItemNS(ANDROID_NS, "permission").nodeValue,
        )
        val provider = manifest.getElementsByTagName("provider").item(0)
        assertEquals(".tablet.c1b.TabletC1bContentProvider", provider.attributes.getNamedItemNS(ANDROID_NS, "name").nodeValue)
        assertEquals(AUTHORITY, provider.attributes.getNamedItemNS(ANDROID_NS, "authorities").nodeValue)
        assertEquals("android.permission.DUMP", provider.attributes.getNamedItemNS(ANDROID_NS, "permission").nodeValue)

        val config = xml(File(projectDir, "src/main/res/xml/a11y_config.xml")).documentElement
        val configAttributes = (0 until config.attributes.length).map { index ->
            config.attributes.item(index)
        }
        assertEquals(
            mapOf(
                "accessibilityEventTypes" to
                    "typeWindowStateChanged|typeWindowContentChanged|typeWindowsChanged",
                "accessibilityFeedbackType" to "feedbackGeneric",
                "accessibilityFlags" to
                    "flagDefault|flagIncludeNotImportantViews|flagReportViewIds|flagRetrieveInteractiveWindows",
                "canRetrieveWindowContent" to "true",
                "description" to "@string/a11y_desc",
                "notificationTimeout" to "50",
            ),
            configAttributes.filter { attribute -> attribute.namespaceURI == ANDROID_NS }
                .associate { attribute -> attribute.localName to attribute.nodeValue },
        )
        assertEquals(7, configAttributes.size)
        assertEquals(
            listOf("xmlns:android=$ANDROID_NS"),
            configAttributes.filter { attribute -> attribute.namespaceURI != ANDROID_NS }
                .map { attribute -> "${attribute.nodeName}=${attribute.nodeValue}" },
        )
        assertFalse(config.hasAttributeNS(ANDROID_NS, "canPerformGestures"))
        assertFalse(config.hasAttributeNS(ANDROID_NS, "canTakeScreenshot"))

        val sourceRoot = File(projectDir, "src/main/java")
        val localSources = sourceRoot.walkTopDown().filter { it.isFile }.toList()
        assertEquals(listOf("dev/magina/gateway/a11y/GatewayA11yService.kt"), localSources.map { source ->
            sourceRoot.toPath().relativize(source.toPath()).toString().replace(File.separatorChar, '/')
        })
        val serviceSource = localSources.single().readText(Charsets.UTF_8)
        assertTrue(serviceSource.contains("var instance: GatewayA11yService?"))
        assertTrue(serviceSource.contains("val revision: Long"))
        assertTrue(serviceSource.contains("onAccessibilityEvent"))
        listOf(
            "performAction(",
            "dispatchGesture(",
            "performGlobalAction(",
            "takeScreenshot(",
            "startActivity(",
            "startService(",
            "sendBroadcast(",
            "InputMethodService",
            "GestureDescription",
            "MediaProjection",
        ).forEach { forbidden -> assertFalse("minimal service contains $forbidden", serviceSource.contains(forbidden)) }
    }

    @Test
    fun accessibilityNodeRefreshIsTheSingleNamedReadFreshnessWaiver() {
        val projectDir = File(requireNotNull(System.getProperty("user.dir")))
        val freshnessSource = File(
            projectDir,
            "../gateway/src/main/java/dev/magina/gateway/tablet/c1b/AndroidTabletC1bSource.kt",
        ).readText(Charsets.UTF_8)
        val refreshCalls = Regex("\\.refresh\\s*\\(").findAll(freshnessSource).toList()
        assertEquals(1, refreshCalls.size)
        assertEquals(1, freshnessSource.split("node.androidNode.refresh()").size - 1)

        val providerSource = File(
            projectDir,
            "../gateway/src/debug/java/dev/magina/gateway/tablet/c1b/TabletC1bContentProvider.kt",
        ).readText(Charsets.UTF_8)
        assertTrue(
            Regex(
                "override\\s+fun\\s+refresh\\([^)]*\\)\\s*:\\s*Boolean\\s*=\\s*" +
                    "rejectNonStreamSurface\\(\\)",
                RegexOption.DOT_MATCHES_ALL,
            ).containsMatchIn(providerSource),
        )
    }

    private fun xml(file: File) = DocumentBuilderFactory.newInstance().apply {
        isNamespaceAware = true
    }.newDocumentBuilder().parse(file)

    private companion object {
        const val ANDROID_NS = "http://schemas.android.com/apk/res/android"
        const val APPLICATION_ID = "dev.magina.gateway"
        const val SERVICE_CLASS = "dev.magina.gateway.a11y.GatewayA11yService"
        const val PROVIDER_CLASS = "dev.magina.gateway.tablet.c1b.TabletC1bContentProvider"
        const val AUTHORITY = "dev.magina.gateway.tablet.c1b"
    }
}
