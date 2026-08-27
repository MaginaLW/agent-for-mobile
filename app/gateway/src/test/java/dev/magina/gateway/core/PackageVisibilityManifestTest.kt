package dev.magina.gateway.core

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/** 钉住 app_launch 的最小包可见性边界，避免重新引入全量应用枚举能力。 */
class PackageVisibilityManifestTest {
    @Test
    fun `manifest queries exactly match registered app aliases`() {
        val manifest = findProjectFile("gateway/src/main/AndroidManifest.xml")
        val aliases = JSONObject(
            findProjectFile("gateway/src/main/assets/skillpack/apps.json").readText(),
        ).getJSONObject("aliases")
        val expectedPackages = aliases.keys().asSequence()
            .map(aliases::getString)
            .toSet()

        val document = DocumentBuilderFactory.newInstance().apply {
            isNamespaceAware = true
        }.newDocumentBuilder().parse(manifest)
        val permissionNames = document.getElementsByTagName("uses-permission").let { nodes ->
            (0 until nodes.length).map { index ->
                nodes.item(index).attributes.getNamedItemNS(ANDROID_NAMESPACE, "name").nodeValue
            }.toSet()
        }
        val queriedPackages = document.getElementsByTagName("package").let { nodes ->
            (0 until nodes.length).map { index ->
                nodes.item(index).attributes.getNamedItemNS(ANDROID_NAMESPACE, "name").nodeValue
            }.toSet()
        }

        assertFalse(
            "gateway 不得恢复 QUERY_ALL_PACKAGES",
            "android.permission.QUERY_ALL_PACKAGES" in permissionNames,
        )
        assertEquals("清单 queries 必须与 apps.json aliases 精确一致", expectedPackages, queriedPackages)
    }

    private fun findProjectFile(pathFromApp: String): File {
        val userDir = requireNotNull(System.getProperty("user.dir")) { "JVM 未提供 user.dir" }
        var cursor: File? = File(userDir).absoluteFile
        while (cursor != null) {
            listOf(File(cursor, pathFromApp), File(cursor, "app/$pathFromApp"))
                .firstOrNull(File::isFile)
                ?.let { return it }
            cursor = cursor.parentFile
        }
        error("找不到 $pathFromApp（user.dir=$userDir）")
    }

    private companion object {
        const val ANDROID_NAMESPACE = "http://schemas.android.com/apk/res/android"
    }
}
