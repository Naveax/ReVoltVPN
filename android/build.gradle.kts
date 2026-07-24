// Root build.gradle.kts — project-level configuration only.
// Application-specific configuration belongs in android/app/build.gradle.kts.

plugins {
    // The Flutter Gradle Plugin is applied at the app-module level, not here.
    id("dev.flutter.flutter-gradle-plugin") apply false
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.layout.buildDirectory.set(layout.projectDirectory.dir("../build"))

subprojects {
    project.layout.buildDirectory.set(
        rootProject.layout.buildDirectory.dir(project.name)
    )
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register("clean", Delete::class) {
    delete(rootProject.layout.buildDirectory)
}
