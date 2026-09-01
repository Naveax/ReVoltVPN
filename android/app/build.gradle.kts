import java.util.Properties
import java.io.File
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
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
val flutterVlessRuntimeHygieneScript = File(
    projectRootDir,
    "tool/patch_flutter_vless_runtime_hygiene.dart",
)
val flutterVlessSecureSocksPatchScript = File(
    projectRootDir,
    "tool/patch_flutter_vless_secure_socks_v2.dart",
)
val flutterVlessSecurityInvariantsScript = File(
    projectRootDir,
    "tool/patch_flutter_vless_security_invariants.dart",
)

val patchFlutterVlessRuntimeHygiene = tasks.register<Exec>("patchFlutterVlessRuntimeHygiene") {
    group = "build setup"
    description = "Remove stale Xray/socket state from pinned flutter_vless_android 1.1.5 before startup"
    workingDir(projectRootDir)

    doFirst {
        if (!dartExecutable.isFile) {
            throw GradleException("Flutter Dart executable not found: ${dartExecutable.absolutePath}")
        }
        if (!flutterVlessRuntimeHygieneScript.isFile) {
            throw GradleException("runtime hygiene patch script missing: ${flutterVlessRuntimeHygieneScript.absolutePath}")
        }
        if (!File(projectRootDir, ".dart_tool/package_config.json").isFile) {
            throw GradleException("Flutter package metadata missing. Run `flutter pub get` before Android compilation.")
        }
    }

    commandLine(
        dartExecutable.absolutePath,
        "run",
        flutterVlessRuntimeHygieneScript.absolutePath,
    )
}

val patchFlutterVlessSecureSocks = tasks.register<Exec>("patchFlutterVlessSecureSocks") {
    group = "build setup"
    description = "Add authenticated ephemeral SOCKS5 and fail-closed process recovery to pinned flutter_vless_android 1.1.5"
    workingDir(projectRootDir)
    dependsOn(patchFlutterVlessRuntimeHygiene)

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

val patchFlutterVlessSecurityInvariants = tasks.register<Exec>("patchFlutterVlessSecurityInvariants") {
    group = "build setup"
    description = "Enforce ReVolt privacy, IPC and full-tunnel invariants on pinned flutter_vless_android 1.1.5"
    workingDir(projectRootDir)
    dependsOn(patchFlutterVlessSecureSocks)

    doFirst {
        if (!dartExecutable.isFile) {
            throw GradleException("Flutter Dart executable not found: ${dartExecutable.absolutePath}")
        }
        if (!flutterVlessSecurityInvariantsScript.isFile) {
            throw GradleException("security invariant patch script missing: ${flutterVlessSecurityInvariantsScript.absolutePath}")
        }
        if (!File(projectRootDir, ".dart_tool/package_config.json").isFile) {
            throw GradleException("Flutter package metadata missing. Run `flutter pub get` before Android compilation.")
        }
    }

    commandLine(
        dartExecutable.absolutePath,
        "run",
        flutterVlessSecurityInvariantsScript.absolutePath,
    )
}

// Both the app and transitive Android plugin compile against the patched source.
tasks.configureEach {
    if (name == "preBuild") {
        dependsOn(patchFlutterVlessSecurityInvariants)
    }
}

gradle.projectsEvaluated {
    rootProject.findProject(":flutter_vless_android")
        ?.tasks
        ?.matching { it.name == "preBuild" }
        ?.configureEach {
            dependsOn(patchFlutterVlessSecurityInvariants)
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

    packaging {
        resources.excludes.add("META-INF/**")
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

    // Explicit opt-in used only by CI to exercise the real release/R8 graph.
    // Normal production release signing remains tied to key.properties.
    val ciReleaseSmoke = System.getenv("REVOLT_CI_RELEASE_SMOKE") == "true"

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
