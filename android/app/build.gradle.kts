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
val flutterVlessPatchScript = File(
    projectRootDir,
    "tool/patch_flutter_vless_allowed_apps.dart",
)
val flutterVlessSecureSocksPatchScript = File(
    projectRootDir,
    "tool/patch_flutter_vless_secure_socks_v2.dart",
)
val flutterVlessSecureSocksScopeFixScript = File(
    projectRootDir,
    "tool/patch_flutter_vless_secure_socks_scope_fix.dart",
)
val flutterVlessRuntimeReliabilityPatchScript = File(
    projectRootDir,
    "tool/patch_flutter_vless_runtime_reliability.dart",
)

val patchFlutterVlessAllowedApps = tasks.register<Exec>("patchFlutterVlessAllowedApps") {
    group = "build setup"
    description = "Patch pinned flutter_vless_android 1.1.5 with ReVolt routing/runtime hardening"
    workingDir(projectRootDir)

    doFirst {
        if (!dartExecutable.isFile) {
            throw GradleException("Flutter Dart executable not found: ${dartExecutable.absolutePath}")
        }
        if (!flutterVlessPatchScript.isFile) {
            throw GradleException("flutter_vless patch script missing: ${flutterVlessPatchScript.absolutePath}")
        }
        if (!File(projectRootDir, ".dart_tool/package_config.json").isFile) {
            throw GradleException("Flutter package metadata missing. Run `flutter pub get` before Android compilation.")
        }
    }

    commandLine(
        dartExecutable.absolutePath,
        "run",
        flutterVlessPatchScript.absolutePath,
    )
}

val patchFlutterVlessSecureSocks = tasks.register<Exec>("patchFlutterVlessSecureSocks") {
    group = "build setup"
    description = "Add authenticated ephemeral SOCKS5 and fail-closed process recovery to pinned flutter_vless_android 1.1.5"
    workingDir(projectRootDir)
    dependsOn(patchFlutterVlessAllowedApps)

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

val patchFlutterVlessRuntimeReliability = tasks.register<Exec>("patchFlutterVlessRuntimeReliability") {
    group = "build setup"
    description = "Add end-to-end runtime health, IPv6 fail-closed routing and power-saver hardening"
    workingDir(projectRootDir)
    dependsOn(patchFlutterVlessSecureSocksScopeFix)

    doFirst {
        if (!dartExecutable.isFile) {
            throw GradleException("Flutter Dart executable not found: ${dartExecutable.absolutePath}")
        }
        if (!flutterVlessRuntimeReliabilityPatchScript.isFile) {
            throw GradleException("runtime reliability patch script missing: ${flutterVlessRuntimeReliabilityPatchScript.absolutePath}")
        }
        if (!File(projectRootDir, ".dart_tool/package_config.json").isFile) {
            throw GradleException("Flutter package metadata missing. Run `flutter pub get` before Android compilation.")
        }
    }

    commandLine(
        dartExecutable.absolutePath,
        "run",
        flutterVlessRuntimeReliabilityPatchScript.absolutePath,
    )
}

// App compilation and the transitive Android plugin compilation must both wait
// for the pinned runtime patches. Plain `flutter build apk` must behave like CI
// instead of relying on a hidden manual pre-build step.
tasks.configureEach {
    if (name == "preBuild") {
        dependsOn(patchFlutterVlessRuntimeReliability)
    }
}

gradle.projectsEvaluated {
    rootProject.findProject(":flutter_vless_android")
        ?.tasks
        ?.matching { it.name == "preBuild" }
        ?.configureEach {
            dependsOn(patchFlutterVlessRuntimeReliability)
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
            signingConfig = signingConfigs.getByName("release")
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
