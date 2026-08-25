import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

val releaseKeystoreFile = rootProject.file("keystore.properties")
val releaseKeystore = Properties()
if (releaseKeystoreFile.isFile) {
    releaseKeystoreFile.inputStream().use(releaseKeystore::load)
}
fun signingValue(property: String, environment: String): String? =
    releaseKeystore.getProperty(property)?.takeIf { it.isNotBlank() }
        ?: System.getenv(environment)?.takeIf { it.isNotBlank() }

val releaseStoreFile = signingValue("storeFile", "HYPERDISPLAY_ANDROID_KEYSTORE")
val releaseStorePassword = signingValue("storePassword", "HYPERDISPLAY_ANDROID_STORE_PASSWORD")
val releaseKeyAlias = signingValue("keyAlias", "HYPERDISPLAY_ANDROID_KEY_ALIAS")
val releaseKeyPassword = signingValue("keyPassword", "HYPERDISPLAY_ANDROID_KEY_PASSWORD")
val hasReleaseSigning = listOf(releaseStoreFile, releaseStorePassword, releaseKeyAlias, releaseKeyPassword)
    .all { !it.isNullOrBlank() }

android {
    namespace = "com.hyperdisplay.client"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.hyperdisplay.client"
        minSdk = 26
        targetSdk = 34
        versionCode = 5
        versionName = "0.3.2"
    }

    if (hasReleaseSigning) {
        signingConfigs {
            create("release") {
                storeFile = file(requireNotNull(releaseStoreFile))
                storePassword = requireNotNull(releaseStorePassword)
                keyAlias = requireNotNull(releaseKeyAlias)
                keyPassword = requireNotNull(releaseKeyPassword)
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
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
    implementation("androidx.appcompat:appcompat:1.6.1")
    // 扫码（与 hypercast 同款、久经验证的组合）
    implementation("com.journeyapps:zxing-android-embedded:4.3.0")
    implementation("com.google.zxing:core:3.5.1")
}
