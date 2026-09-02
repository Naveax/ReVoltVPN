import java.util.Properties
import java.io.File
import java.io.FileInputStream
import java.security.MessageDigest

fun sha256Hex(file: File): String {
    val digest = MessageDigest.getInstance("SHA-256").digest(file.readBytes())
    return digest.joinToString("") { "%02x".format(it.toInt() and 0xff) }
}

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.paladinvpn.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    val keystorePropertiesFile = rootProject.file("key.properties")
    val keystoreProperties = Properties()
    if (keystorePropertiesFile.exists()) {
        keystoreProperties.load(FileInputStream(keystorePropertiesFile))
    }

    val admobPropertiesFile = rootProject.file("admob.properties")
    val admobProperties = Properties()
    if (admobPropertiesFile.exists()) {
        admobProperties.load(FileInputStream(admobPropertiesFile))
    }

    // Explicit opt-in used only by GitHub Actions to exercise the real
    // release/R8 graph. Production release signing and config pinning remain
    // fail-closed outside that CI smoke path.
    val ciReleaseSmoke =
        System.getenv("GITHUB_ACTIONS") == "true" &&
            System.getenv("REVOLT_CI_RELEASE_SMOKE") == "true"

    val appConfigFile = rootProject.file("../lib/logic/app_config.dart")
    val verifyReleaseAppConfig = tasks.register("verifyReleaseAppConfig") {
        group = "verification"
        description = "Verify the production Dart app config against REVOLT_APP_CONFIG_SHA256."
        doLast {
            if (ciReleaseSmoke) {
                logger.lifecycle("Skipping production app-config pin for CI release smoke build")
                return@doLast
            }

            val expected = System.getenv("REVOLT_APP_CONFIG_SHA256")?.trim()?.lowercase()
            if (expected.isNullOrEmpty()) {
                throw org.gradle.api.GradleException(
                    "REVOLT_APP_CONFIG_SHA256 is required for production release builds"
                )
            }
            if (!Regex("[0-9a-f]{64}").matches(expected)) {
                throw org.gradle.api.GradleException(
                    "REVOLT_APP_CONFIG_SHA256 must be exactly 64 lowercase hexadecimal characters"
                )
            }
            if (!appConfigFile.isFile) {
                throw org.gradle.api.GradleException(
                    "Production app config is missing: ${appConfigFile.absolutePath}"
                )
            }

            val configText = appConfigFile.readText()
            val templateMarkers = listOf(
                "'0.0.0.0'",
                "YOUR_DOMAIN",
                "YOUR_GITHUB_USERNAME",
                "YOUR_REPO_NAME",
                "ca-app-pub-0000000000000000/0000000000",
            )
            val remainingMarker = templateMarkers.firstOrNull(configText::contains)
            if (remainingMarker != null) {
                throw org.gradle.api.GradleException(
                    "Production app config still contains template marker: $remainingMarker"
                )
            }

            val actual = sha256Hex(appConfigFile)
            if (actual != expected) {
                throw org.gradle.api.GradleException(
                    "Production app config SHA-256 mismatch: expected $expected, got $actual"
                )
            }
        }
    }

    tasks.matching { it.name == "preReleaseBuild" }.configureEach {
        dependsOn(verifyReleaseAppConfig)
    }

    defaultConfig {
        applicationId = "com.paladinvpn.app"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["ADMOB_APP_ID"] = admobProperties.getProperty("ADMOB_APP_ID", "ca-app-pub-0000000000000000~0000000000")
    }

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String?
            keyPassword = keystoreProperties["keyPassword"] as String?
            storeFile = keystoreProperties["storeFile"]?.let { rootProject.file(it) }
            storePassword = keystoreProperties["storePassword"] as String?
        }
    }

    buildTypes {
        release {
            signingConfig = if (ciReleaseSmoke) {
                signingConfigs.getByName("debug")
            } else {
                signingConfigs.getByName("release")
            }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation("androidx.core:core-ktx:1.13.1")
}
