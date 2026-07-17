plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "dev.magina.a11yprobe"
    compileSdk = 35

    defaultConfig {
        applicationId = "dev.magina.a11yprobe"
        minSdk = 30
        targetSdk = 35
        versionCode = 1
        versionName = "0.1"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    // S3：ML Kit 中文 OCR，bundled 版（模型打进 APK，不依赖 GMS——vivo 国行必须用这个）
    implementation("com.google.mlkit:text-recognition-chinese:16.0.1")
}
