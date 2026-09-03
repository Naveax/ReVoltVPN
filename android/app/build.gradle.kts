import java.util.Properties
import java.io.File
import java.io.FileInputStream
import java.security.MessageDigest

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

fun sha256Hex(file: File): String {
    val digest = MessageDigest.getInstance("SHA-256").digest(file.readBytes())
    return digest.joinToString("") { "%02x".format(it.toInt() and 0xff) }
}

val projectRootDir = rootProject.projectDir.parentFile
val localPropertiesFile = rootProject.file("local.properties")
val localProperties = Properties().apply {
    if (localPropertiesFile.exists()) {
        localPropertiesFile.inputStream().use { load(it) }
    }
}
val flutterSdkPath = localProperties.getProperty("flutter.sdk")
    ?: throw GradleException("flutter.sdk not set in android/local.properties")
val dartExecutable = File(
    flutterSdkPath,
    if (System.getProperty("os.name").lowercase().contains("windows")) {
        "bin/cache/dart-sdk/bin/dart.exe"
    } else {
        "bin/cache/dart-sdk/bin/dart"
    },
)
val flutterVlessRecoveryPatchScript = File(
    projectRootDir,
    "tool/patch_flutter_vless_runtime_recovery.dart",
)
val flutterVlessSecureSocksPatchScript = File(
    projectRootDir,
    "tool/patch_flutter_vless_secure_socks_v2.dart",
)
val flutterVlessSecureSocksScopeFixScript = File(
    projectRootDir,
    "tool/patch_flutter_vless_secure_socks_scope_fix.dart",
)

val patchFlutterVlessRuntimeRecovery = tasks.register<Exec>("patchFlutterVlessRuntimeRecovery") {
    group = "build setup"
    description = "Recover stale Xray core and tun2socks socket before restart"
    workingDir(projectRootDir)

    doFirst {
        if (!dartExecutable.isFile) {
            throw GradleException("Flutter Dart executable not found: ${dartExecutable.absolutePath}")
        }
        if (!flutterVlessRecoveryPatchScript.isFile) {
            throw GradleException("flutter_vless recovery patch script missing: ${flutterVlessRecoveryPatchScript.absolutePath}")
        }
        if (!File(projectRootDir, ".dart_tool/package_config.json").isFile) {
            throw GradleException("Flutter package metadata missing. Run `flutter pub get` before Android compilation.")
        }
    }

    commandLine(
        dartExecutable.absolutePath,
        "run",
        flutterVlessRecoveryPatchScript.absolutePath,
    )
}

val patchFlutterVlessSecureSocks = tasks.register<Exec>("patchFlutterVlessSecureSocks") {
    group = "build setup"
    description = "Add authenticated ephemeral SOCKS5 and fail-closed process recovery to pinned flutter_vless_android 1.1.5"
    workingDir(projectRootDir)
    dependsOn(patchFlutterVlessRuntimeRecovery)

    doFirst {
        if (!dartExecutable.isFile) {
            throw GradleException("Flutter Dart executable not found: ${dartExecutable.absolutePath}")
        }
        if (!flutterVlessSecureSocksPatchScript.isFile) {
            throw GradleException("secure SOCKS patch script missing: ${flutterVlessSecureSocksPatchScript.absolutePath}")
        }
        if (!File(projectRootDir, ".dart_tool/package_config.json").isFile) {
            throw GradleException("Flutter package metadata missing. Run `flutter pub get` before Android compilation.")
        }
    }

    commandLine(
        dartExecutable.absolutePath,
        "run",
        flutterVlessSecureSocksPatchScript.absolutePath,
    )
}

val patchFlutterVlessSecureSocksScopeFix = tasks.register<Exec>("patchFlutterVlessSecureSocksScopeFix") {
    group = "build setup"
    description = "Repair the secure Xray process monitor capture without changing stock 1.1.5 runtime sequencing"
    workingDir(projectRootDir)
    dependsOn(patchFlutterVlessSecureSocks)

    doFirst {
        if (!dartExecutable.isFile) {
            throw GradleException("Flutter Dart executable not found: ${dartExecutable.absolutePath}")
        }
        if (!flutterVlessSecureSocksScopeFixScript.isFile) {
            throw GradleException("secure SOCKS scope fix script missing: ${flutterVlessSecureSocksScopeFixScript.absolutePath}")
        }
        if (!File(projectRootDir, ".dart_tool/package_config.json").isFile) {
            throw GradleException("Flutter package metadata missing. Run `flutter pub get` before Android compilation.")
        }
    }

    commandLine(
        dartExecutable.absolutePath,
        "run",
        flutterVlessSecureSocksScopeFixScript.absolutePath,
    )
}

// App compilation and the transitive Android plugin compilation must both wait
// for the pinned runtime patches. Plain `flutter build apk` must behave like CI
// instead of relying on a hidden manual pre-build step.
tasks.configureEach {
    if (name == "preBuild") {
        dependsOn(patchFlutterVlessSecureSocksScopeFix)
    }
}

gradle.projectsEvaluated {
    rootProject.findProject(":flutter_vless_android")
        ?.tasks
        ?.matching { it.name == "preBuild" }
        ?.configureEach {
            dependsOn(patchFlutterVlessSecureSocksScopeFix)
        }
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
