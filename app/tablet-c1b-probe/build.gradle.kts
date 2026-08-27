import groovy.json.JsonOutput
import java.io.File
import java.security.MessageDigest
import java.util.zip.ZipFile
import javax.xml.XMLConstants
import javax.xml.parsers.DocumentBuilderFactory
import org.w3c.dom.Element

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

private val C1B_APPLICATION_ID = "dev.magina.gateway"
private val C1B_SERVICE = "dev.magina.gateway.a11y.GatewayA11yService"
private val C1B_PROVIDER = "dev.magina.gateway.tablet.c1b.TabletC1bContentProvider"
private val C1B_AUTHORITY = "dev.magina.gateway.tablet.c1b"
private val ANDROID_NAMESPACE = "http://schemas.android.com/apk/res/android"
private val C1B_BUILD_TOOLS_VERSION = "35.0.0"
private val C1B_AAPT2_RELATIVE_PATH = "build-tools/35.0.0/aapt2.exe"
private val C1B_AAPT2_SHA256 =
    "sha256:cbfe5deda5f7074ce47b6f33818b456ee8046a076a11af13e29c837d3c80c564"

private val c1bGitHead = providers.exec {
    workingDir(rootProject.projectDir)
    commandLine("git", "rev-parse", "HEAD")
}.standardOutput.asText.get().trim().also { value ->
    check(Regex("[0-9a-f]{40}").matches(value)) {
        "T-L1 C1b read-only artifact requires a full lowercase Git HEAD"
    }
}

private val c1bExpectedGitHead = providers.environmentVariable("TL1_C1B_EXPECTED_COMMIT_SHA")
    .orNull
    ?.also { value ->
        check(Regex("[0-9a-f]{40}").matches(value)) {
            "TL1_C1B_EXPECTED_COMMIT_SHA must be a full lowercase Git SHA"
        }
        check(value == c1bGitHead) {
            "TL1_C1B_EXPECTED_COMMIT_SHA does not match the checked-out Git HEAD"
        }
    }

private val c1bBuildChallenge = providers.environmentVariable("TABLET_C1B_BUILD_CHALLENGE")
    .orElse("offline-c1b-read-only-placeholder")
    .get()
    .also { value ->
        check(Regex("[a-z0-9][a-z0-9._-]{15,95}").matches(value)) {
            "TABLET_C1B_BUILD_CHALLENGE must be a 16..96 character safe lowercase token"
        }
    }

private fun quotedBuildConfigString(value: String): String =
    "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"") + "\""

private val productionSourceIncludes = listOf(
    "GatewayA11yService.kt",
    "TabletLayoutProbe.kt",
    "TabletLayoutProbeModel.kt",
    "c1b/AndroidTabletC1bSource.kt",
    "c1b/TabletC1bModel.kt",
    "c1b/TabletC1bProbe.kt",
    "C1bPendingStartRegistry.kt",
    "TabletC1bContentProvider.kt",
    "TabletC1bProtocol.kt",
    "TabletC1bReadCoordinator.kt",
    "TabletC1bRuntimeController.kt",
    "TrustedRuntimeContextFactory.kt",
)

private val testSourceIncludes = listOf(
    "TabletC1bReadOnlyModuleTest.kt",
    "TabletC1bProbeTest.kt",
    "C1bPendingStartRegistryTest.kt",
    "TabletC1bProtocolTest.kt",
    "TabletC1bReadCoordinatorTest.kt",
    "TabletC1bRuntimeControllerTest.kt",
)

/**
 * Exact top-level JVM class roots produced by the twelve allowlisted production sources. A `$...`
 * suffix is permitted only for compiler-generated/nested classes under one of these roots. This is
 * deliberately not a package-prefix allowlist: unrelated tablet adapters must fail the DEX gate.
 */
private val allowedAppDescriptorRoots = sortedSetOf(
    "dev/magina/gateway/BuildConfig",
    "dev/magina/gateway/R",
    "dev/magina/gateway/a11y/GatewayA11yService",
    "dev/magina/gateway/tablet/ProbeCapture",
    "dev/magina/gateway/tablet/ProbeConsistency",
    "dev/magina/gateway/tablet/ProbeDisplay",
    "dev/magina/gateway/tablet/ProbeFocusObservation",
    "dev/magina/gateway/tablet/ProbeImeMode",
    "dev/magina/gateway/tablet/ProbeImeObservation",
    "dev/magina/gateway/tablet/ProbeInputCandidate",
    "dev/magina/gateway/tablet/ProbeNodeObservation",
    "dev/magina/gateway/tablet/ProbePane",
    "dev/magina/gateway/tablet/ProbePaneBinding",
    "dev/magina/gateway/tablet/ProbePaneRole",
    "dev/magina/gateway/tablet/ProbeRect",
    "dev/magina/gateway/tablet/ProbeRegionCandidate",
    "dev/magina/gateway/tablet/ProbeRootStatus",
    "dev/magina/gateway/tablet/ProbeSize",
    "dev/magina/gateway/tablet/ProbeTargetObservation",
    "dev/magina/gateway/tablet/ProbeTitleCandidate",
    "dev/magina/gateway/tablet/ProbeTitleContentMatch",
    "dev/magina/gateway/tablet/ProbeWindow",
    "dev/magina/gateway/tablet/RawProbeDisplay",
    "dev/magina/gateway/tablet/RawProbeIme",
    "dev/magina/gateway/tablet/RawTabletNode",
    "dev/magina/gateway/tablet/RawTabletProbeFrame",
    "dev/magina/gateway/tablet/RawTabletWindow",
    "dev/magina/gateway/tablet/StrictProbeJsonParser",
    "dev/magina/gateway/tablet/StrictProbeJsonValue",
    "dev/magina/gateway/tablet/TabletLayoutObservation",
    "dev/magina/gateway/tablet/TabletLayoutProbe",
    "dev/magina/gateway/tablet/TabletLayoutProbeKt",
    "dev/magina/gateway/tablet/TabletLayoutProbeModelKt",
    "dev/magina/gateway/tablet/TabletLayoutProbeProductionCapability",
    "dev/magina/gateway/tablet/TabletProbeFrame",
    "dev/magina/gateway/tablet/TabletProbeProvenance",
    "dev/magina/gateway/tablet/TabletProbeRunContext",
    "dev/magina/gateway/tablet/TabletProbeUpstreamT0",
    "dev/magina/gateway/tablet/c1b/AndroidC1bNode",
    "dev/magina/gateway/tablet/c1b/AndroidC1bWindow",
    "dev/magina/gateway/tablet/c1b/AndroidTabletC1bReadPort",
    "dev/magina/gateway/tablet/c1b/AndroidTabletC1bSource",
    "dev/magina/gateway/tablet/c1b/AndroidTabletC1bSourceKt",
    "dev/magina/gateway/tablet/c1b/C1bAssemblyRequest",
    "dev/magina/gateway/tablet/c1b/C1bCaptureMetadata",
    "dev/magina/gateway/tablet/c1b/C1bCaptureRequest",
    "dev/magina/gateway/tablet/c1b/C1bConsistency",
    "dev/magina/gateway/tablet/c1b/C1bDeadlineCancellation",
    "dev/magina/gateway/tablet/c1b/C1bDeadlineScheduler",
    "dev/magina/gateway/tablet/c1b/C1bDisplayRead",
    "dev/magina/gateway/tablet/c1b/C1bEndpoint",
    "dev/magina/gateway/tablet/c1b/C1bFocusObservation",
    "dev/magina/gateway/tablet/c1b/C1bFocusStatus",
    "dev/magina/gateway/tablet/c1b/C1bFrameAssembler",
    "dev/magina/gateway/tablet/c1b/C1bFrameReader",
    "dev/magina/gateway/tablet/c1b/C1bGeometryStatus",
    "dev/magina/gateway/tablet/c1b/C1bImeObservation",
    "dev/magina/gateway/tablet/c1b/C1bNodeHandle",
    "dev/magina/gateway/tablet/c1b/C1bNodeIdentityToken",
    "dev/magina/gateway/tablet/c1b/C1bNodeObservation",
    "dev/magina/gateway/tablet/c1b/C1bPaneObservation",
    "dev/magina/gateway/tablet/c1b/C1bPendingAwait",
    "dev/magina/gateway/tablet/c1b/C1bPendingStartRegistry",
    "dev/magina/gateway/tablet/c1b/C1bProbeLimits",
    "dev/magina/gateway/tablet/c1b/C1bProtocolBuildIdentity",
    "dev/magina/gateway/tablet/c1b/C1bProtocolControl",
    "dev/magina/gateway/tablet/c1b/C1bProtocolState",
    "dev/magina/gateway/tablet/c1b/C1bProvenance",
    "dev/magina/gateway/tablet/c1b/C1bRawFrame",
    "dev/magina/gateway/tablet/c1b/C1bReadSnapshot",
    "dev/magina/gateway/tablet/c1b/C1bReadState",
    "dev/magina/gateway/tablet/c1b/C1bReadWorker",
    "dev/magina/gateway/tablet/c1b/C1bRect",
    "dev/magina/gateway/tablet/c1b/C1bResultRead",
    "dev/magina/gateway/tablet/c1b/C1bRootHandleStatus",
    "dev/magina/gateway/tablet/c1b/C1bRunLease",
    "dev/magina/gateway/tablet/c1b/C1bRuntimeFrameCapture",
    "dev/magina/gateway/tablet/c1b/C1bRuntimeResult",
    "dev/magina/gateway/tablet/c1b/C1bSessionKey",
    "dev/magina/gateway/tablet/c1b/C1bStartEnvelope",
    "dev/magina/gateway/tablet/c1b/C1bSubtreeObservation",
    "dev/magina/gateway/tablet/c1b/C1bSubtreeStatus",
    "dev/magina/gateway/tablet/c1b/C1bTitleMatchStatus",
    "dev/magina/gateway/tablet/c1b/C1bUpstreamT0",
    "dev/magina/gateway/tablet/c1b/C1bWindowBinding",
    "dev/magina/gateway/tablet/c1b/C1bWindowHandle",
    "dev/magina/gateway/tablet/c1b/C1bWindowObservation",
    "dev/magina/gateway/tablet/c1b/ReadAttempt",
    "dev/magina/gateway/tablet/c1b/TabletC1bAssembler",
    "dev/magina/gateway/tablet/c1b/TabletC1bContentProvider",
    "dev/magina/gateway/tablet/c1b/TabletC1bModelKt",
    "dev/magina/gateway/tablet/c1b/TabletC1bObservation",
    "dev/magina/gateway/tablet/c1b/TabletC1bProbe",
    "dev/magina/gateway/tablet/c1b/TabletC1bProbeKt",
    "dev/magina/gateway/tablet/c1b/TabletC1bProtocol",
    "dev/magina/gateway/tablet/c1b/TabletC1bProtocolKt",
    "dev/magina/gateway/tablet/c1b/TabletC1bReadCoordinator",
    "dev/magina/gateway/tablet/c1b/TabletC1bReadPort",
    "dev/magina/gateway/tablet/c1b/TabletC1bRuntimeController",
    "dev/magina/gateway/tablet/c1b/TabletC1bRuntimeControllerKt",
    "dev/magina/gateway/tablet/c1b/TrustedRuntimeContextFactory",
    "dev/magina/gateway/tablet/c1b/TrustedRuntimeContextFactoryKt",
)

private val allowedRuntimeArtifactHashes = sortedMapOf(
    "org.jetbrains.kotlin:kotlin-stdlib:2.0.20" to
        "sha256:fb169596659a518357c4b2c16f43dc75ab1c4980565ed4b4a317a050e5e39006",
    "org.jetbrains:annotations:13.0" to
        "sha256:ace2a10dc8e2d5fd34925ecac03e4988b2c0f851650c94b8cef49ba1bd111478",
)

android {
    namespace = C1B_APPLICATION_ID
    compileSdk = 35
    buildToolsVersion = C1B_BUILD_TOOLS_VERSION

    defaultConfig {
        applicationId = C1B_APPLICATION_ID
        minSdk = 30
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0-c1b-read-only"
        buildConfigField("String", "TABLET_C1B_GIT_HEAD", quotedBuildConfigString(c1bGitHead))
        buildConfigField(
            "String",
            "TABLET_C1B_BUILD_CHALLENGE",
            quotedBuildConfigString(c1bBuildChallenge),
        )
    }

    buildTypes {
        getByName("debug") {
            vcsInfo.include = false
        }
        getByName("release") {
            isMinifyEnabled = false
            vcsInfo.include = false
        }
    }

    buildFeatures {
        buildConfig = true
    }

    sourceSets {
        getByName("main") {
            java.setSrcDirs(emptyList<String>())
        }
        getByName("test") {
            java.setSrcDirs(emptyList<String>())
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    packaging {
        resources.excludes += setOf(
            "kotlin/**",
            "kotlin-tooling-metadata.json",
            "META-INF/*.kotlin_module",
        )
    }
    lint {
        // The replacement probe has no launcher surface or persistent app data by design.
        disable += setOf("DataExtractionRules", "MissingApplicationIcon")
        warningsAsErrors = true
    }
}

kotlin {
    sourceSets {
        getByName("main").kotlin.apply {
            setSrcDirs(
                listOf(
                    "src/main/java/dev/magina/gateway/a11y",
                    "../gateway/src/main/java/dev/magina/gateway/tablet",
                    "../gateway/src/debug/java/dev/magina/gateway/tablet/c1b",
                ),
            )
            include(productionSourceIncludes)
        }
        getByName("test").kotlin.apply {
            setSrcDirs(
                listOf(
                    "src/test/java/dev/magina/gateway/tablet/c1b",
                    "../gateway/src/test/java/dev/magina/gateway/tablet/c1b",
                    "../gateway/src/testDebug/java/dev/magina/gateway/tablet/c1b",
                ),
            )
            include(testSourceIncludes)
        }
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}

private fun ByteArray.sha256Hex(): String = "sha256:" + MessageDigest.getInstance("SHA-256")
    .digest(this)
    .joinToString("") { byte -> "%02x".format(byte) }

private fun File.sha256Hex(): String = readBytes().sha256Hex()

private fun ByteArray.containsAscii(value: String): Boolean {
    val needle = value.toByteArray(Charsets.US_ASCII)
    if (needle.isEmpty() || needle.size > size) return false
    return (0..size - needle.size).any { offset ->
        needle.indices.all { index -> this[offset + index] == needle[index] }
    }
}

private fun ByteArray.containsBinaryXmlString(value: String): Boolean {
    fun containsTerminated(needle: ByteArray, terminatorSize: Int): Boolean {
        if (needle.isEmpty() || needle.size + terminatorSize > size) return false
        return (0..size - needle.size - terminatorSize).any { offset ->
            needle.indices.all { index -> this[offset + index] == needle[index] } &&
                (0 until terminatorSize).all { index -> this[offset + needle.size + index] == 0.toByte() }
        }
    }
    return containsTerminated(value.toByteArray(Charsets.UTF_8), 1) ||
        containsTerminated(value.toByteArray(Charsets.UTF_16LE), 2)
}

private fun dexEntryOrdinal(name: String): Int? = when (name) {
    "classes.dex" -> 1
    else -> Regex("classes([2-9]|[1-9][0-9]+)\\.dex").matchEntire(name)
        ?.groupValues
        ?.get(1)
        ?.toIntOrNull()
        ?.takeIf { ordinal -> ordinal in 2..32 }
}

private fun parseXml(file: File) = DocumentBuilderFactory.newInstance().apply {
    isNamespaceAware = true
    setFeature(XMLConstants.FEATURE_SECURE_PROCESSING, true)
    setFeature("http://apache.org/xml/features/disallow-doctype-decl", true)
    setFeature("http://xml.org/sax/features/external-general-entities", false)
    setFeature("http://xml.org/sax/features/external-parameter-entities", false)
    isXIncludeAware = false
    setExpandEntityReferences(false)
}.newDocumentBuilder().parse(file)

private fun Element.androidAttribute(name: String): String = getAttributeNS(ANDROID_NAMESPACE, name)

private fun resolveComponentName(name: String): String = when {
    name.startsWith(".") -> C1B_APPLICATION_ID + name
    "." in name -> name
    else -> "$C1B_APPLICATION_ID.$name"
}

private data class ManifestVerification(
    val sha256: String,
    val mutatingCapabilityCount: Int,
    val extraComponentCount: Int,
)

private data class Aapt2XmlTree(
    val namespaceDeclarations: List<String>,
    val elementPaths: List<String>,
    val attributesByPath: Map<String, Map<String, String>>,
)

private data class Aapt2XmlDump(
    val text: String,
    val sha256: String,
)

private fun androidAapt2Attribute(name: String, resourceId: String): String =
    "$ANDROID_NAMESPACE:$name($resourceId)"

private fun aapt2RawString(value: String): String = "\"$value\" (Raw: \"$value\")"

private fun parseAapt2XmlTree(text: String): Aapt2XmlTree {
    val stack = mutableListOf<Pair<Int, String>>()
    val namespaceDeclarations = mutableListOf<String>()
    val elementPaths = mutableListOf<String>()
    val attributesByPath = linkedMapOf<String, MutableMap<String, String>>()
    text.lineSequence().forEachIndexed { lineNumber, line ->
        val trimmed = line.trimStart()
        val indent = line.length - trimmed.length
        when {
            trimmed.startsWith("N: ") -> {
                val declaration = trimmed.removePrefix("N: ").substringBefore(" (line=")
                check(declaration == "android=$ANDROID_NAMESPACE") {
                    "aapt2 emitted a non-allowlist namespace at line ${lineNumber + 1}"
                }
                namespaceDeclarations += declaration
            }

            trimmed.startsWith("E: ") -> {
                val element = trimmed.removePrefix("E: ").substringBefore(" (line=")
                check(Regex("[A-Za-z0-9_.-]+").matches(element)) {
                    "aapt2 emitted an invalid element at line ${lineNumber + 1}"
                }
                while (stack.lastOrNull()?.first?.let { previousIndent -> previousIndent >= indent } == true) {
                    stack.removeAt(stack.lastIndex)
                }
                stack += indent to element
                val path = stack.joinToString("/") { (_, name) -> name }
                elementPaths += path
                attributesByPath.putIfAbsent(path, linkedMapOf())
            }

            trimmed.startsWith("A: ") -> {
                check(stack.isNotEmpty()) { "aapt2 emitted an attribute without an element" }
                val expression = trimmed.removePrefix("A: ")
                val equalsIndex = expression.indexOf('=')
                check(equalsIndex > 0) { "aapt2 emitted an invalid attribute at line ${lineNumber + 1}" }
                val descriptor = expression.substring(0, equalsIndex)
                val unnamespacedAttribute = Regex("[A-Za-z][A-Za-z0-9_.-]*")
                val androidAttribute = Regex(
                    "${Regex.escape(ANDROID_NAMESPACE)}:[A-Za-z][A-Za-z0-9_.-]*\\(0x[0-9a-f]{8}\\)",
                )
                check(unnamespacedAttribute.matches(descriptor) || androidAttribute.matches(descriptor)) {
                    "aapt2 emitted a non-allowlist attribute descriptor at line ${lineNumber + 1}"
                }
                val encodedValue = expression.substring(equalsIndex + 1)
                val path = stack.joinToString("/") { (_, element) -> element }
                check(attributesByPath.getValue(path).put(descriptor, encodedValue) == null) {
                    "aapt2 emitted duplicate $path@$descriptor"
                }
            }

            trimmed.isNotBlank() -> error(
                "aapt2 emitted a non-allowlist XML-tree record at line ${lineNumber + 1}",
            )
        }
    }
    check(elementPaths.isNotEmpty()) { "aapt2 emitted an empty XML tree" }
    return Aapt2XmlTree(
        namespaceDeclarations = namespaceDeclarations.toList(),
        elementPaths = elementPaths,
        attributesByPath = attributesByPath.mapValues { (_, attributes) -> attributes.toMap() },
    )
}

private fun verifyPackagedManifestTree(tree: Aapt2XmlTree, variant: String) {
    check(tree.namespaceDeclarations == listOf("android=$ANDROID_NAMESPACE")) {
        "$variant packaged manifest namespace declarations differ: ${tree.namespaceDeclarations}"
    }
    val expectedPaths = listOf(
        "manifest",
        "manifest/uses-sdk",
        "manifest/application",
        "manifest/application/service",
        "manifest/application/service/intent-filter",
        "manifest/application/service/intent-filter/action",
        "manifest/application/service/meta-data",
        "manifest/application/provider",
    )
    check(tree.elementPaths == expectedPaths) {
        "$variant packaged manifest has missing/extra/reordered elements: ${tree.elementPaths}"
    }
    fun exact(path: String, expected: Map<String, String>) {
        check(tree.attributesByPath.getValue(path) == expected) {
            "$variant packaged manifest attributes differ at $path: " +
                tree.attributesByPath.getValue(path)
        }
    }
    exact(
        "manifest",
        linkedMapOf(
            androidAapt2Attribute("versionCode", "0x0101021b") to "1",
            androidAapt2Attribute("versionName", "0x0101021c") to
                aapt2RawString("0.1.0-c1b-read-only"),
            androidAapt2Attribute("compileSdkVersion", "0x01010572") to "35",
            androidAapt2Attribute("compileSdkVersionCodename", "0x01010573") to
                aapt2RawString("15"),
            "package" to aapt2RawString(C1B_APPLICATION_ID),
            "platformBuildVersionCode" to "35",
            "platformBuildVersionName" to "15",
        ),
    )
    exact(
        "manifest/uses-sdk",
        linkedMapOf(
            androidAapt2Attribute("minSdkVersion", "0x0101020c") to "30",
            androidAapt2Attribute("targetSdkVersion", "0x01010270") to "35",
        ),
    )
    val expectedApplicationAttributes = linkedMapOf(
        androidAapt2Attribute("label", "0x01010001") to "@0x7f010001",
        androidAapt2Attribute("allowBackup", "0x01010280") to "false",
        androidAapt2Attribute("extractNativeLibs", "0x010104ea") to "false",
    ).apply {
        if (variant == "debug") {
            put(androidAapt2Attribute("debuggable", "0x0101000f"), "true")
        }
    }
    val actualApplicationAttributes = tree.attributesByPath.getValue("manifest/application")
    check(actualApplicationAttributes == expectedApplicationAttributes) {
        "$variant packaged application attributes differ: $actualApplicationAttributes"
    }
    exact(
        "manifest/application/service",
        linkedMapOf(
            androidAapt2Attribute("name", "0x01010003") to aapt2RawString(C1B_SERVICE),
            androidAapt2Attribute("permission", "0x01010006") to
                aapt2RawString("android.permission.BIND_ACCESSIBILITY_SERVICE"),
            androidAapt2Attribute("exported", "0x01010010") to "false",
        ),
    )
    exact("manifest/application/service/intent-filter", emptyMap())
    exact(
        "manifest/application/service/intent-filter/action",
        mapOf(
            androidAapt2Attribute("name", "0x01010003") to
                aapt2RawString("android.accessibilityservice.AccessibilityService"),
        ),
    )
    val metadata = tree.attributesByPath.getValue("manifest/application/service/meta-data")
    val metadataNameAttribute = androidAapt2Attribute("name", "0x01010003")
    val metadataResourceAttribute = androidAapt2Attribute("resource", "0x01010025")
    check(metadata.keys == setOf(metadataNameAttribute, metadataResourceAttribute) &&
        metadata[metadataNameAttribute] == aapt2RawString("android.accessibilityservice") &&
        metadata[metadataResourceAttribute] == "@0x7f020000") {
        "$variant packaged accessibility metadata differs: $metadata"
    }
    exact(
        "manifest/application/provider",
        linkedMapOf(
            androidAapt2Attribute("name", "0x01010003") to aapt2RawString(C1B_PROVIDER),
            androidAapt2Attribute("permission", "0x01010006") to
                aapt2RawString("android.permission.DUMP"),
            androidAapt2Attribute("exported", "0x01010010") to "true",
            androidAapt2Attribute("authorities", "0x01010018") to aapt2RawString(C1B_AUTHORITY),
            androidAapt2Attribute("grantUriPermissions", "0x0101001b") to "false",
        ),
    )
}

private fun verifyPackagedA11yTree(tree: Aapt2XmlTree, variant: String) {
    check(tree.namespaceDeclarations == listOf("android=$ANDROID_NAMESPACE")) {
        "$variant packaged accessibility config namespace declarations differ: " +
            tree.namespaceDeclarations
    }
    check(tree.elementPaths == listOf("accessibility-service")) {
        "$variant packaged accessibility config has extra elements: ${tree.elementPaths}"
    }
    val attributes = tree.attributesByPath.getValue("accessibility-service")
    val expected = linkedMapOf(
        androidAapt2Attribute("description", "0x01010020") to "@0x7f010000",
        androidAapt2Attribute("accessibilityEventTypes", "0x01010380") to "0x00400820",
        androidAapt2Attribute("accessibilityFeedbackType", "0x01010382") to "0x00000010",
        androidAapt2Attribute("notificationTimeout", "0x01010383") to "50",
        androidAapt2Attribute("accessibilityFlags", "0x01010384") to "0x00000053",
        androidAapt2Attribute("canRetrieveWindowContent", "0x01010385") to "true",
    )
    check(attributes == expected) {
        "$variant packaged accessibility config attributes differ: $attributes"
    }
}

private fun verifyMergedManifest(file: File): ManifestVerification {
    val document = parseXml(file)
    val manifest = document.documentElement
    check(manifest.tagName == "manifest") { "merged manifest root is not <manifest>: $file" }
    check(manifest.getAttribute("package") == C1B_APPLICATION_ID) {
        "merged manifest package is not the replacement application id: $file"
    }

    val permissionCount = document.getElementsByTagName("uses-permission").length +
        document.getElementsByTagName("uses-permission-sdk-23").length
    val componentTags = listOf("activity", "activity-alias", "service", "receiver", "provider")
    val components = componentTags.flatMap { tag ->
        val nodes = document.getElementsByTagName(tag)
        (0 until nodes.length).map { index -> tag to (nodes.item(index) as Element) }
    }
    val expectedComponents = setOf("service:$C1B_SERVICE", "provider:$C1B_PROVIDER")
    val actualComponents = components.map { (tag, element) ->
        "$tag:${resolveComponentName(element.androidAttribute("name"))}"
    }
    val extraComponentCount = actualComponents.count { it !in expectedComponents } +
        expectedComponents.count { it !in actualComponents }

    check(permissionCount == 0) { "read-only artifact requests Android permissions: $file" }
    check(extraComponentCount == 0 && actualComponents.size == expectedComponents.size) {
        "read-only artifact has missing or extra Android components: $actualComponents"
    }

    val service = components.single { (tag, _) -> tag == "service" }.second
    check(resolveComponentName(service.androidAttribute("name")) == C1B_SERVICE)
    check(service.androidAttribute("exported") == "false")
    check(service.androidAttribute("permission") == "android.permission.BIND_ACCESSIBILITY_SERVICE")
    val serviceActions = service.getElementsByTagName("action")
    check(serviceActions.length == 1)
    check((serviceActions.item(0) as Element).androidAttribute("name") ==
        "android.accessibilityservice.AccessibilityService")
    val serviceMetadata = service.getElementsByTagName("meta-data")
    check(serviceMetadata.length == 1)
    check((serviceMetadata.item(0) as Element).androidAttribute("name") ==
        "android.accessibilityservice")
    check((serviceMetadata.item(0) as Element).androidAttribute("resource") == "@xml/a11y_config")

    val provider = components.single { (tag, _) -> tag == "provider" }.second
    check(resolveComponentName(provider.androidAttribute("name")) == C1B_PROVIDER)
    check(provider.androidAttribute("authorities") == C1B_AUTHORITY)
    check(provider.androidAttribute("exported") == "true")
    check(provider.androidAttribute("grantUriPermissions") == "false")
    check(provider.androidAttribute("permission") == "android.permission.DUMP")

    return ManifestVerification(
        sha256 = file.sha256Hex(),
        mutatingCapabilityCount = permissionCount,
        extraComponentCount = extraComponentCount,
    )
}

private val proofFile = layout.buildDirectory.file(
    "reports/tablet-c1b-read-only-artifact-proof.json",
)

tasks.register("verifyTabletC1bReadOnlyArtifact") {
    group = "verification"
    description = "Verify the dedicated T-L1 C1b APK contains only the closed read-only surface"
    dependsOn(
        "assembleDebug",
        "assembleRelease",
        "processDebugMainManifest",
        "processReleaseMainManifest",
    )
    outputs.file(proofFile)
    outputs.upToDateWhen { false }

    doLast {
        val repositoryRoot = rootProject.projectDir.parentFile.canonicalFile
        fun repoRelative(file: File): String = repositoryRoot.toPath()
            .relativize(file.canonicalFile.toPath())
            .toString()
            .replace(File.separatorChar, '/')

        check(System.getProperty("os.name").startsWith("Windows", ignoreCase = true)) {
            "T-L1 C1b AXML verification is pinned to the reviewed Windows aapt2 binary"
        }
        val sdkDirectory = androidComponents.sdkComponents.sdkDirectory.get().asFile.canonicalFile
        val androidHomeValue = requireNotNull(
            providers.environmentVariable("ANDROID_HOME").orNull?.takeIf(String::isNotBlank),
        ) { "T-L1 C1b requires ANDROID_HOME" }
        val androidSdkRootValue = requireNotNull(
            providers.environmentVariable("ANDROID_SDK_ROOT").orNull?.takeIf(String::isNotBlank),
        ) { "T-L1 C1b requires ANDROID_SDK_ROOT" }
        val androidHome = File(androidHomeValue).also { path ->
            check(path.isAbsolute) { "T-L1 C1b requires an absolute ANDROID_HOME" }
        }.canonicalFile
        val androidSdkRoot = File(androidSdkRootValue).also { path ->
            check(path.isAbsolute) { "T-L1 C1b requires an absolute ANDROID_SDK_ROOT" }
        }.canonicalFile
        check(androidHome.isDirectory && androidSdkRoot.isDirectory &&
            androidHome.path.equals(androidSdkRoot.path, ignoreCase = true) &&
            androidHome.path.equals(sdkDirectory.path, ignoreCase = true)) {
            "T-L1 C1b requires AGP, ANDROID_HOME, and ANDROID_SDK_ROOT to resolve to one SDK root"
        }
        val aapt2 = File(sdkDirectory, C1B_AAPT2_RELATIVE_PATH).canonicalFile
        check(aapt2.isFile && aapt2.sha256Hex() == C1B_AAPT2_SHA256) {
            "T-L1 C1b requires the exact reviewed build-tools 35.0.0 aapt2 binary"
        }
        fun dumpPackagedXml(apk: File, entryName: String): Aapt2XmlDump {
            val bytes = providers.exec {
                commandLine(
                    aapt2.absolutePath,
                    "dump",
                    "xmltree",
                    apk.absolutePath,
                    "--file",
                    entryName,
                )
            }.standardOutput.asBytes.get()
            val normalizedText = bytes.toString(Charsets.UTF_8)
                .replace("\r\n", "\n")
                .replace('\r', '\n')
            return Aapt2XmlDump(
                text = normalizedText,
                sha256 = normalizedText.toByteArray(Charsets.UTF_8).sha256Hex(),
            ).also { bytes.fill(0) }
        }

        val expectedSources = listOf(
            file("src/main/java/dev/magina/gateway/a11y/GatewayA11yService.kt"),
            file("../gateway/src/main/java/dev/magina/gateway/tablet/TabletLayoutProbe.kt"),
            file("../gateway/src/main/java/dev/magina/gateway/tablet/TabletLayoutProbeModel.kt"),
            file("../gateway/src/main/java/dev/magina/gateway/tablet/c1b/AndroidTabletC1bSource.kt"),
            file("../gateway/src/main/java/dev/magina/gateway/tablet/c1b/TabletC1bModel.kt"),
            file("../gateway/src/main/java/dev/magina/gateway/tablet/c1b/TabletC1bProbe.kt"),
            file("../gateway/src/debug/java/dev/magina/gateway/tablet/c1b/C1bPendingStartRegistry.kt"),
            file("../gateway/src/debug/java/dev/magina/gateway/tablet/c1b/TabletC1bContentProvider.kt"),
            file("../gateway/src/debug/java/dev/magina/gateway/tablet/c1b/TabletC1bProtocol.kt"),
            file("../gateway/src/debug/java/dev/magina/gateway/tablet/c1b/TabletC1bReadCoordinator.kt"),
            file("../gateway/src/debug/java/dev/magina/gateway/tablet/c1b/TabletC1bRuntimeController.kt"),
            file("../gateway/src/debug/java/dev/magina/gateway/tablet/c1b/TrustedRuntimeContextFactory.kt"),
        ).map(File::getCanonicalFile).sortedBy(::repoRelative)
        check(expectedSources.all(File::isFile)) { "a required C1b source is missing" }

        val configuredSources = kotlin.sourceSets.getByName("main").kotlin.files
            .filter { source -> source.extension.lowercase() in setOf("kt", "java") }
            .map(File::getCanonicalFile)
            .sortedBy(::repoRelative)
        check(configuredSources == expectedSources) {
            "C1b production source inputs differ from the exact allowlist:\n" +
                "expected=${expectedSources.map(::repoRelative)}\nactual=${configuredSources.map(::repoRelative)}"
        }

        val forbiddenSourcePatterns = linkedMapOf(
            "gateway-mutating-import" to Regex(
                "(?m)^\\s*import\\s+dev\\.magina\\.gateway\\." +
                    "(?:core|ime|mcp|ocr|overlay|tools|testing)(?:\\.|$)",
            ),
            "platform-mutating-import" to Regex(
                "(?m)^\\s*import\\s+(?:" +
                    "android\\.(?:inputmethodservice|media\\.projection)(?:\\.|$)|" +
                    "android\\.(?:content\\.ContentResolver|graphics\\.Bitmap|provider\\.Settings)|" +
                    "android\\.view\\.inputmethod\\.InputConnection|" +
                    "dalvik\\.system\\.(?:DexClassLoader|PathClassLoader)|" +
                    "java\\.io\\.(?:FileOutputStream|FileWriter|RandomAccessFile)|" +
                    "java\\.lang\\.reflect(?:\\.|$)|" +
                    "java\\.net\\.(?:Socket|ServerSocket|URL|URLConnection|HttpURLConnection)|" +
                    "java\\.nio\\.file\\.Files)",
            ),
            "android-mutator-call" to Regex(
                "\\b(?:performAction|dispatchGesture|performGlobalAction|takeScreenshot|startActivity|" +
                    "startService|startForegroundService|sendBroadcast|commitText|sendKeyEvent|" +
                    "deleteSurroundingText)\\s*\\(",
            ),
            "android-mutator-class" to Regex(
                "\\b(?:Bitmap|ContentResolver|DexClassLoader|FileOutputStream|FileWriter|GestureDescription|" +
                    "InputConnection|InputMethodService|MediaProjection|OcrEngine|PathClassLoader|" +
                    "ProcessBuilder|ServerSocket|Socket|URLConnection)\\b",
            ),
            "file-network-process-call" to Regex(
                "(?:\\bFiles\\s*\\.\\s*(?:write|writeString|newOutputStream)\\s*\\(|" +
                    "\\bRuntime\\s*\\.\\s*getRuntime\\s*\\(\\s*\\)\\s*\\.\\s*exec\\s*\\(|" +
                    "\\bProcessBuilder\\s*\\()",
            ),
            "reflection-call" to Regex(
                "(?:\\bClass\\s*\\.\\s*forName\\s*\\(|" +
                    "\\.(?:getMethod|getDeclaredMethod|invoke)\\s*\\()",
            ),
        )
        val sourceForbiddenMatches = expectedSources.flatMap { source ->
            val text = source.readText(Charsets.UTF_8)
            forbiddenSourcePatterns.mapNotNull { (name, pattern) ->
                if (pattern.containsMatchIn(text)) "${repoRelative(source)}:$name" else null
            }
        }
        check(sourceForbiddenMatches.isEmpty()) {
            "mutating API or class appears in C1b source inputs: $sourceForbiddenMatches"
        }

        val freshnessSource = expectedSources.single { source ->
            source.name == "AndroidTabletC1bSource.kt"
        }
        val freshnessInvocation = "node.androidNode.refresh()"
        val refreshInvocations = expectedSources.flatMap { source ->
            Regex("\\.refresh\\s*\\(").findAll(source.readText(Charsets.UTF_8))
                .map { match -> repoRelative(source) to match.value }
                .toList()
        }
        check(refreshInvocations.size == 1 &&
            freshnessSource.readText(Charsets.UTF_8).split(freshnessInvocation).size == 2) {
            "the named AccessibilityNodeInfo.refresh read-freshness waiver is not unique: $refreshInvocations"
        }
        val providerSource = expectedSources.single { source -> source.name == "TabletC1bContentProvider.kt" }
        check(Regex(
            "override\\s+fun\\s+refresh\\([^)]*\\)\\s*:\\s*Boolean\\s*=\\s*" +
                "rejectNonStreamSurface\\(\\)",
            setOf(RegexOption.DOT_MATCHES_ALL),
        ).containsMatchIn(providerSource.readText(Charsets.UTF_8))) {
            "ContentProvider.refresh must remain a fail-closed non-stream surface"
        }

        val a11yConfig = file("src/main/res/xml/a11y_config.xml")
        val a11yRoot = parseXml(a11yConfig).documentElement
        check(a11yRoot.tagName == "accessibility-service")
        val actualA11yAttributes = (0 until a11yRoot.attributes.length).map { index ->
            a11yRoot.attributes.item(index)
        }.filter { attribute -> attribute.namespaceURI == ANDROID_NAMESPACE }
            .associate { attribute -> attribute.localName to attribute.nodeValue }
        val expectedA11yAttributes = linkedMapOf(
            "accessibilityEventTypes" to
                "typeWindowStateChanged|typeWindowContentChanged|typeWindowsChanged",
            "accessibilityFeedbackType" to "feedbackGeneric",
            "accessibilityFlags" to
                "flagDefault|flagIncludeNotImportantViews|flagReportViewIds|flagRetrieveInteractiveWindows",
            "canRetrieveWindowContent" to "true",
            "description" to "@string/a11y_desc",
            "notificationTimeout" to "50",
        )
        check(actualA11yAttributes == expectedA11yAttributes) {
            "C1b accessibility config attributes differ from the exact read-only allowlist: " +
                actualA11yAttributes
        }
        val namespaceDeclarations = (0 until a11yRoot.attributes.length).map { index ->
            a11yRoot.attributes.item(index)
        }.filter { attribute -> attribute.namespaceURI != ANDROID_NAMESPACE }
        check(a11yRoot.attributes.length == expectedA11yAttributes.size + 1 &&
            namespaceDeclarations.size == 1 &&
            namespaceDeclarations.single().nodeName == "xmlns:android" &&
            namespaceDeclarations.single().namespaceURI == XMLConstants.XMLNS_ATTRIBUTE_NS_URI &&
            namespaceDeclarations.single().nodeValue == ANDROID_NAMESPACE) {
            "C1b accessibility config contains a non-allowlist namespace or attribute"
        }
        val a11yChildElements = (0 until a11yRoot.childNodes.length).count { index ->
            a11yRoot.childNodes.item(index) is Element
        }
        check(a11yChildElements == 0) {
            "C1b accessibility config must not contain child capabilities"
        }

        val resolvedDependencyArtifacts = listOf("debugRuntimeClasspath", "releaseRuntimeClasspath")
            .flatMap { configurationName ->
                configurations.getByName(configurationName).resolvedConfiguration.resolvedArtifacts.map { artifact ->
                    val id = artifact.moduleVersion.id
                    val coordinate = "${id.group}:${id.name}:${id.version}"
                    linkedMapOf(
                        "coordinate" to coordinate,
                        "artifact_sha256" to artifact.file.sha256Hex(),
                    )
                }
            }
            .distinct()
            .sortedBy { artifact -> artifact.getValue("coordinate") }
        val expectedDependencyArtifacts = allowedRuntimeArtifactHashes.map { (coordinate, artifactSha256) ->
            linkedMapOf(
                "coordinate" to coordinate,
                "artifact_sha256" to artifactSha256,
            )
        }
        val forbiddenDependencies = resolvedDependencyArtifacts.filter { artifact ->
            allowedRuntimeArtifactHashes[artifact.getValue("coordinate")] !=
                artifact.getValue("artifact_sha256")
        }
        check(forbiddenDependencies.isEmpty() && resolvedDependencyArtifacts == expectedDependencyArtifacts) {
            "runtime dependency coordinate/hash closure differs from the exact allowlist: " +
                "expected=$expectedDependencyArtifacts actual=$resolvedDependencyArtifacts"
        }

        val manifestByVariant = linkedMapOf<String, Pair<File, ManifestVerification>>()
        listOf("debug", "release").forEach { variant ->
            val capitalizedVariant = variant.replaceFirstChar { character -> character.uppercase() }
            val manifest = layout.buildDirectory.file(
                "intermediates/merged_manifests/$variant/process${capitalizedVariant}Manifest/AndroidManifest.xml",
            ).get().asFile.canonicalFile
            check(manifest.isFile) { "final $variant merged manifest is missing: ${repoRelative(manifest)}" }
            manifestByVariant[variant] = manifest to verifyMergedManifest(manifest)
        }

        val forbiddenDexStrings = listOf(
            "AndroidTabletLayoutProbeSource",
            "performAction",
            "dispatchGesture",
            "performGlobalAction",
            "takeScreenshot",
            "startActivity",
            "startService",
            "startForegroundService",
            "sendBroadcast",
            "GestureDescription",
            "Bitmap",
            "ContentResolver",
            "DexClassLoader",
            "FileOutputStream",
            "FileWriter",
            "InputConnection",
            "InputMethodService",
            "MediaProjection",
            "OcrEngine",
            "PathClassLoader",
            "ProcessBuilder",
            "ServerSocket",
            "URLConnection",
            "android/provider/Settings",
            "commitText",
            "deleteSurroundingText",
            "forName",
            "getMethod",
            "java/lang/Runtime",
            "java/lang/reflect",
            "java/net/Socket",
            "java/nio/file/Files",
            "sendKeyEvent",
            "dev/magina/gateway/mcp/",
            "dev/magina/gateway/ime/",
            "dev/magina/gateway/ocr/",
            "dev/magina/gateway/overlay/",
            "dev/magina/gateway/tools/",
            "dev/magina/gateway/core/",
        )
        val appDescriptor = Regex("Ldev/magina/gateway/[A-Za-z0-9_$/]+;")
        fun allowedAppDescriptor(descriptor: String): Boolean {
            val body = descriptor.removePrefix("L").removeSuffix(";")
            return allowedAppDescriptorRoots.any { root ->
                body == root || body.startsWith("$root\$")
            }
        }

        val dependencyDexStringWaivers = sortedSetOf(
            "FileOutputStream",
            "forName",
            "getMethod",
            "java/lang/Runtime",
            "java/lang/reflect",
            "java/nio/file/Files",
        )

        val variantProofs = mutableListOf<Map<String, Any>>()
        var dexForbiddenMatchCount = 0
        var bytecodeForbiddenMatchCount = 0
        var entryForbiddenMatchCount = 0
        listOf("debug", "release").forEach { variant ->
            val apks = fileTree(layout.buildDirectory.dir("outputs/apk/$variant")) {
                include("*.apk")
            }.files.map(File::getCanonicalFile).sortedBy(::repoRelative)
            check(apks.size == 1) { "expected one $variant APK, found ${apks.map(::repoRelative)}" }
            val apk = apks.single()
            val dexProofs = mutableListOf<Map<String, String>>()
            val kotlinClassRoot = layout.buildDirectory.dir("tmp/kotlin-classes/$variant").get().asFile
                .canonicalFile
            val kotlinClassFiles = fileTree(kotlinClassRoot) {
                include("**/*.class")
            }.files.map(File::getCanonicalFile).distinct()
            val actualKotlinClassRoots = kotlinClassFiles.map { classFile ->
                kotlinClassRoot.toPath().relativize(classFile.canonicalFile.toPath())
                    .toString()
                    .replace(File.separatorChar, '/')
                    .removeSuffix(".class")
                    .substringBefore('$')
            }.toSortedSet()
            val expectedKotlinClassRoots = allowedAppDescriptorRoots
                .filterNot { root -> root == "dev/magina/gateway/BuildConfig" || root == "dev/magina/gateway/R" }
                .toSortedSet()
            check(actualKotlinClassRoots == expectedKotlinClassRoots) {
                "$variant Kotlin class roots differ from the exact source-derived allowlist: " +
                    "missing=${expectedKotlinClassRoots - actualKotlinClassRoots} " +
                "extra=${actualKotlinClassRoots - expectedKotlinClassRoots}"
            }
            val javacClassFiles = fileTree(layout.buildDirectory.dir("intermediates/javac/$variant")) {
                include("**/*.class")
            }.files.map(File::getCanonicalFile).distinct()
            val classesMarker = "${File.separator}classes${File.separator}"
            val actualJavacClassRoots = javacClassFiles.map { classFile ->
                val path = classFile.path
                check(classesMarker in path) { "unexpected javac class path: ${repoRelative(classFile)}" }
                path.substringAfterLast(classesMarker)
                    .replace(File.separatorChar, '/')
                    .removeSuffix(".class")
                    .substringBefore('$')
            }.toSortedSet()
            check(actualJavacClassRoots == sortedSetOf("dev/magina/gateway/BuildConfig")) {
                "$variant javac class roots differ from the exact generated allowlist: $actualJavacClassRoots"
            }
            val appClassFiles = (kotlinClassFiles + javacClassFiles).distinct()
            check(appClassFiles.isNotEmpty()) { "$variant app bytecode output is missing" }
            val appBytecodeForbiddenStrings = forbiddenDexStrings.filter { needle ->
                appClassFiles.any { classFile -> classFile.readBytes().containsAscii(needle) }
            }
            bytecodeForbiddenMatchCount += appBytecodeForbiddenStrings.size
            check(appBytecodeForbiddenStrings.isEmpty()) {
                "forbidden mutator/reference entered $variant app bytecode: $appBytecodeForbiddenStrings"
            }
            var packagedManifestSha256 = ""
            var packagedManifestAxmlDumpSha256 = ""
            var packagedA11yAxmlDumpSha256 = ""
            ZipFile(apk).use { zip ->
                val entries = zip.entries().asSequence().toList().sortedBy { it.name }
                val invalidEntries = entries.map { it.name }.filterNot { name ->
                    name == "AndroidManifest.xml" || dexEntryOrdinal(name) != null ||
                        name == "resources.arsc" ||
                        name.matches(Regex("res/(?:[^/]+/)?[^/]+\\.xml")) ||
                        name == "META-INF/com/android/build/gradle/app-metadata.properties"
                }
                entryForbiddenMatchCount += invalidEntries.size
                check(invalidEntries.isEmpty()) { "non-allowlist APK entries in $variant: $invalidEntries" }
                check(entries.none { it.name.startsWith("assets/") || it.name.startsWith("lib/") })
                val packagedManifest = zip.getInputStream(
                    requireNotNull(zip.getEntry("AndroidManifest.xml")) {
                        "$variant APK is missing AndroidManifest.xml"
                    },
                ).use { input -> input.readBytes() }
                packagedManifestSha256 = packagedManifest.sha256Hex()
                val expectedPackagedManifestStrings = listOf(
                    C1B_APPLICATION_ID,
                    C1B_SERVICE,
                    C1B_PROVIDER,
                    C1B_AUTHORITY,
                    "android.accessibilityservice.AccessibilityService",
                    "android.permission.BIND_ACCESSIBILITY_SERVICE",
                    "android.permission.DUMP",
                    "provider",
                    "service",
                )
                val forbiddenPackagedManifestStrings = listOf(
                    "activity",
                    "activity-alias",
                    "receiver",
                    "instrumentation",
                    "uses-permission",
                    "input-method",
                    "android.permission.BIND_INPUT_METHOD",
                    "android.permission.CAPTURE_VIDEO_OUTPUT",
                    "android.permission.FOREGROUND_SERVICE",
                    "android.permission.INTERNET",
                    "android.permission.MEDIA_CONTENT_CONTROL",
                    "android.permission.REQUEST_INSTALL_PACKAGES",
                    "android.permission.SYSTEM_ALERT_WINDOW",
                    "android.permission.WRITE_SETTINGS",
                )
                val missingManifestStrings = expectedPackagedManifestStrings.filterNot { expected ->
                    packagedManifest.containsBinaryXmlString(expected)
                }
                val forbiddenManifestStrings = forbiddenPackagedManifestStrings.filter { forbidden ->
                    packagedManifest.containsBinaryXmlString(forbidden)
                }
                entryForbiddenMatchCount += forbiddenManifestStrings.size
                check(missingManifestStrings.isEmpty() && forbiddenManifestStrings.isEmpty()) {
                    "$variant packaged manifest string pool violates the exact read-only policy: " +
                        "missing=$missingManifestStrings forbidden=$forbiddenManifestStrings"
                }
                val packagedManifestDump = dumpPackagedXml(apk, "AndroidManifest.xml")
                verifyPackagedManifestTree(parseAapt2XmlTree(packagedManifestDump.text), variant)
                packagedManifestAxmlDumpSha256 = packagedManifestDump.sha256
                packagedManifest.fill(0)

                val resourceEntries = entries.filter { entry ->
                    entry.name.matches(Regex("res/(?:[^/]+/)?[^/]+\\.xml"))
                }
                check(resourceEntries.size == 1) {
                    "$variant APK must contain exactly one compiled XML resource: ${resourceEntries.map { it.name }}"
                }
                val a11yResource = zip.getInputStream(resourceEntries.single()).use { input -> input.readBytes() }
                check(a11yResource.containsBinaryXmlString("canRetrieveWindowContent") &&
                    !a11yResource.containsBinaryXmlString("canPerformGestures") &&
                    !a11yResource.containsBinaryXmlString("canTakeScreenshot")) {
                    "$variant packaged accessibility config is not read-only"
                }
                val packagedA11yDump = dumpPackagedXml(apk, resourceEntries.single().name)
                verifyPackagedA11yTree(parseAapt2XmlTree(packagedA11yDump.text), variant)
                packagedA11yAxmlDumpSha256 = packagedA11yDump.sha256
                a11yResource.fill(0)
                val dexEntries = entries.mapNotNull { entry ->
                    dexEntryOrdinal(entry.name)?.let { ordinal -> ordinal to entry }
                }.sortedBy { (ordinal, _) -> ordinal }
                check(dexEntries.isNotEmpty()) { "$variant APK has no DEX entries" }
                check(dexEntries.map { (ordinal, _) -> ordinal } == (1..dexEntries.size).toList()) {
                    "$variant APK DEX entries are not a continuous classes.dex/classesN.dex sequence: " +
                        dexEntries.map { (_, entry) -> entry.name }
                }
                dexEntries.forEach { (_, entry) ->
                    val dex = zip.getInputStream(entry).use { it.readBytes() }
                    val forbiddenStrings = forbiddenDexStrings.filter { needle ->
                        needle !in dependencyDexStringWaivers && dex.containsAscii(needle)
                    }
                    val waivedDependencyStrings = dependencyDexStringWaivers.filter { needle ->
                        dex.containsAscii(needle)
                    }
                    check(waivedDependencyStrings.all { waived ->
                        appBytecodeForbiddenStrings.none { it == waived }
                    })
                    val descriptors = appDescriptor.findAll(dex.toString(Charsets.ISO_8859_1))
                        .map { match -> match.value }
                        .distinct()
                        .filterNot(::allowedAppDescriptor)
                        .toList()
                    dexForbiddenMatchCount += forbiddenStrings.size + descriptors.size
                    check(forbiddenStrings.isEmpty() && descriptors.isEmpty()) {
                        "mutating or non-allowlist classes in $variant DEX: " +
                            "strings=$forbiddenStrings descriptors=$descriptors"
                    }
                    dexProofs.add(linkedMapOf(
                        "relative_path" to entry.name,
                        "sha256" to dex.sha256Hex(),
                    ))
                    dex.fill(0)
                }
            }
            val manifest = requireNotNull(manifestByVariant[variant])
            variantProofs.add(linkedMapOf(
                "name" to variant,
                "apk_relative_path" to repoRelative(apk),
                "apk_sha256" to apk.sha256Hex(),
                "merged_manifest_sha256" to manifest.second.sha256,
                "packaged_manifest_sha256" to packagedManifestSha256,
                "packaged_manifest_axml_dump_sha256" to packagedManifestAxmlDumpSha256,
                "packaged_a11y_axml_dump_sha256" to packagedA11yAxmlDumpSha256,
                "packaged_manifest_exact_tree_verified" to true,
                "packaged_a11y_exact_tree_verified" to true,
                "dex_entries" to dexProofs.toList(),
            ))
        }

        val manifestMutatingCapabilityCount = manifestByVariant.values
            .sumOf { (_, verification) -> verification.mutatingCapabilityCount }
        val manifestExtraComponentCount = manifestByVariant.values
            .sumOf { (_, verification) -> verification.extraComponentCount }
        val forbiddenMatchCount = sourceForbiddenMatches.size + dexForbiddenMatchCount +
            bytecodeForbiddenMatchCount +
            entryForbiddenMatchCount + forbiddenDependencies.size
        check(forbiddenMatchCount == 0)
        check(manifestMutatingCapabilityCount == 0)
        check(manifestExtraComponentCount == 0)

        val scannedSources = expectedSources.map { source ->
            linkedMapOf(
                "relative_path" to repoRelative(source),
                "sha256" to source.sha256Hex(),
            )
        }
        val requiredBuildInputs = listOf(
            file("build.gradle.kts"),
            rootProject.file("settings.gradle.kts"),
            rootProject.file("build.gradle.kts"),
            rootProject.file("gradle.properties"),
            rootProject.file("gradlew.bat"),
            rootProject.file("gradle/wrapper/gradle-wrapper.properties"),
            rootProject.file("gradle/wrapper/gradle-wrapper.jar"),
            file("src/main/AndroidManifest.xml"),
            file("src/main/res/values/strings.xml"),
            file("src/main/res/xml/a11y_config.xml"),
        ).map(File::getCanonicalFile)
        check(requiredBuildInputs.all(File::isFile)) {
            "a required C1b build input is missing: " +
                requiredBuildInputs.filterNot(File::isFile).map(::repoRelative)
        }
        val verificationMetadata = rootProject.file("gradle/verification-metadata.xml")
            .canonicalFile
            .takeIf(File::isFile)
        val scannedBuildInputs = (requiredBuildInputs + listOfNotNull(verificationMetadata))
            .distinct()
            .sortedBy(::repoRelative)
            .map { input ->
            linkedMapOf(
                "relative_path" to repoRelative(input),
                "sha256" to input.sha256Hex(),
            )
        }
        val proof = linkedMapOf<String, Any>(
            "schema" to "tablet-c1b-read-only-artifact-proof/v1",
            "policy" to "tl1-c1b-read-only/v2",
            "git_sha" to c1bGitHead,
            "build_challenge_sha256" to c1bBuildChallenge.toByteArray(Charsets.UTF_8).sha256Hex(),
            "application_id" to C1B_APPLICATION_ID,
            "accessibility_service_component" to C1B_SERVICE,
            "provider_component" to C1B_PROVIDER,
            "provider_authority" to C1B_AUTHORITY,
            "forbidden_match_count" to forbiddenMatchCount,
            "manifest_mutating_capability_count" to manifestMutatingCapabilityCount,
            "manifest_extra_component_count" to manifestExtraComponentCount,
            "dependency_allowlist" to linkedMapOf(
                "passed" to true,
                "resolved_artifacts" to resolvedDependencyArtifacts,
            ),
            "axml_parser" to linkedMapOf(
                "tool" to "aapt2",
                "build_tools_version" to C1B_BUILD_TOOLS_VERSION,
                "aapt2_relative_path" to C1B_AAPT2_RELATIVE_PATH,
                "aapt2_sha256" to C1B_AAPT2_SHA256,
            ),
            "named_read_only_waivers" to listOf(
                linkedMapOf(
                    "id" to "accessibility-node-refresh-read-freshness",
                    "relative_path" to repoRelative(freshnessSource),
                    "exact_invocation" to freshnessInvocation,
                    "count" to 1,
                ),
            ),
            "dex_dependency_string_waivers" to dependencyDexStringWaivers.toList(),
            "scanned_sources" to scannedSources,
            "scanned_build_inputs" to scannedBuildInputs,
            "variants" to variantProofs.sortedBy { variant -> variant.getValue("name").toString() },
        )
        val output = proofFile.get().asFile
        output.parentFile.mkdirs()
        output.writeText(JsonOutput.prettyPrint(JsonOutput.toJson(proof)) + "\n", Charsets.UTF_8)
    }
}
