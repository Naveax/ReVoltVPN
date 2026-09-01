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
val flutterVlessRuntimePatchDriver = File(
    projectRootDir,
    "tool/patch_flutter_vless_runtime_driver.dart",
)

val patchFlutterVlessRuntime = tasks.register<Exec>("patchFlutterVlessRuntime") {
    group = "build setup"
    description = "Apply the complete pinned flutter_vless_android 1.1.5 ReVolt runtime patch exactly once"
    workingDir(projectRootDir)

    doFirst {
        if (!dartExecutable.isFile) {
            throw GradleException("Flutter Dart executable not found: ${dartExecutable.absolutePath}")
        }
        if (!flutterVlessRuntimePatchDriver.isFile) {
            throw GradleException("flutter_vless runtime patch driver missing: ${flutterVlessRuntimePatchDriver.absolutePath}")
        }
        if (!File(projectRootDir, ".dart_tool/package_config.json").isFile) {
            throw GradleException("Flutter package metadata missing. Run `flutter pub get` before Android compilation.")
        }
    }

    commandLine(
        dartExecutable.absolutePath,
        "run",
        flutterVlessRuntimePatchDriver.absolutePath,
    )
}

// App compilation and the transitive Android plugin compilation must both wait
// for the same idempotent runtime driver. This avoids replaying intermediate
// patch shapes against a warm pub-cache on a second local/CI build.
tasks.configureEach {
    if (name == "preBuild") {
        dependsOn(patchFlutterVlessRuntime)
    }
}

gradle.projectsEvaluated {
    rootProject.findProject(":flutter_vless_android")
        ?.tasks
        ?.matching { it.name == "preBuild" }
        ?.configureEach {
            dependsOn(patchFlutterVlessRuntime)
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
