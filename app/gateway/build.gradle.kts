plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

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
