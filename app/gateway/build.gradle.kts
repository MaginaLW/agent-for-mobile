import java.util.zip.ZipFile

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

private val c1aGitHead = providers.exec {
    workingDir(rootProject.projectDir)
    commandLine("git", "rev-parse", "HEAD")
}.standardOutput.asText.get().trim().also { value ->
    check(Regex("[0-9a-f]{40}").matches(value)) {
        "T-L1 C1a requires a full lowercase Git HEAD"
    }
}

private val c1aExpectedGitHead = providers.environmentVariable("TL1_C1A_EXPECTED_COMMIT_SHA")
    .orNull
    ?.also { value ->
        check(Regex("[0-9a-f]{40}").matches(value)) {
            "TL1_C1A_EXPECTED_COMMIT_SHA must be a full lowercase Git SHA"
        }
        check(value == c1aGitHead) {
            "TL1_C1A_EXPECTED_COMMIT_SHA does not match the checked-out Git HEAD"
        }
    }

private val c1aBuildChallenge = providers.environmentVariable("TABLET_C1A_BUILD_CHALLENGE")
    .orElse("offline-placeholder-do-not-attest")
    .get()
    .also { value ->
        check(Regex("[a-z0-9][a-z0-9._-]{15,95}").matches(value)) {
            "TABLET_C1A_BUILD_CHALLENGE must be a 16..96 character safe lowercase token"
        }
    }

private fun quotedBuildConfigString(value: String): String =
    "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"") + "\""

android {
    namespace = "dev.magina.gateway"
    compileSdk = 35

    defaultConfig {
        applicationId = "dev.magina.gateway"
        minSdk = 30
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0-m1a"

    }

    buildTypes {
        getByName("debug") {
            buildConfigField("String", "TABLET_C1A_GIT_HEAD", quotedBuildConfigString(c1aGitHead))
            buildConfigField(
                "String",
                "TABLET_C1A_BUILD_CHALLENGE",
                quotedBuildConfigString(c1aBuildChallenge),
            )
        }
    }

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    packaging {
        resources.excludes += setOf("META-INF/INDEX.LIST", "META-INF/io.netty.versions.properties")
    }
}

/**
 * Release 产物的三重机械防线：merged manifest、DEX catalog、静态 source-set 都不能出现
 * debug-only C1a package。任务不依赖设备，也不会读取或写入任何设备状态。
 */
tasks.register("verifyTabletC1aReleaseAbsence") {
    group = "verification"
    description = "Verify that the T-L1 C1a provider is absent from release artifacts"
    dependsOn("processReleaseMainManifest", "assembleRelease")

    doLast {
        val c1aPackageDotPrefix = "dev.magina.gateway.tablet.c1a"
        val c1aPackageSlashPrefix = "dev/magina/gateway/tablet/c1a"
        val forbidden = listOf(
            c1aPackageDotPrefix,
            c1aPackageSlashPrefix,
            "TABLET_C1A_",
        )

        val mergedManifests = fileTree(layout.buildDirectory.dir("intermediates")) {
            include("**/release/**/AndroidManifest.xml")
        }.files.filter { file -> file.path.contains("merged", ignoreCase = true) }
        check(mergedManifests.isNotEmpty()) { "release merged manifest was not generated" }
        mergedManifests.forEach { manifest ->
            val text = manifest.readText(Charsets.UTF_8)
            check(forbidden.none(text::contains)) {
                "debug-only C1a package leaked into release merged manifest: $manifest"
            }
        }

        val releaseApks = fileTree(layout.buildDirectory.dir("outputs/apk/release")) {
            include("*.apk")
        }.files
        check(releaseApks.isNotEmpty()) { "release APK was not generated" }
        releaseApks.forEach { apk ->
            ZipFile(apk).use { zip ->
                val dexEntries = zip.entries().asSequence().filter { it.name.matches(Regex("classes[0-9]*\\.dex")) }
                    .toList()
                check(dexEntries.isNotEmpty()) { "release APK has no DEX catalog: $apk" }
                dexEntries.forEach { entry ->
                    val dex = zip.getInputStream(entry).use { it.readBytes() }
                    check(forbidden.none { needle -> dex.containsAscii(needle) }) {
                        "debug-only C1a package leaked into release DEX catalog: ${entry.name}"
                    }
                }
            }
        }

        listOf(file("src/main"), file("src/release")).forEach { sourceRoot ->
            if (sourceRoot.exists()) {
                sourceRoot.walkTopDown().filter(File::isFile).forEach { source ->
                    val bytes = source.readBytes()
                    check(forbidden.none { needle -> bytes.containsAscii(needle) }) {
                        "debug-only C1a package leaked into non-debug source set: $source"
                    }
                }
            }
        }
    }
}

private fun ByteArray.containsAscii(value: String): Boolean {
    val needle = value.toByteArray(Charsets.US_ASCII)
    if (needle.isEmpty() || needle.size > size) return false
    return (0..size - needle.size).any { offset ->
        needle.indices.all { index -> this[offset + index] == needle[index] }
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
    // MCP server 传输层（Streamable HTTP）。CIO 引擎轻量、无 netty，适合 Android 内嵌。
    implementation("io.ktor:ktor-server-core:2.3.12")
    implementation("io.ktor:ktor-server-cio:2.3.12")
    // L5 视觉通道：ML Kit 中文 OCR bundled 版（vivo 国行无 GMS 必须 bundled，APK 增重 ~20-40MB；Spike S3 实测达标）
    implementation("com.google.mlkit:text-recognition-chinese:16.0.1")

    testImplementation("junit:junit:4.13.2")
    // Android 自带 org.json 在本地 JVM 测试中只有桩实现；测试侧使用真实实现，不进入生产 APK。
    testImplementation("org.json:json:20240303")
}
