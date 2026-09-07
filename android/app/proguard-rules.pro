# ReVoltVPN ProGuard / R8 Rules
# ==============================================================================
# These rules prevent R8 from stripping classes and methods that are accessed
# via JNI (Java Native Interface) or reflection, which would cause
# UnsatisfiedLinkError / ClassNotFoundException at runtime.

# ── VLESS / Xray Native Backend (flutter_vless) ───────────────────────────────
# The flutter_vless plugin embeds Xray core via JNI. Keep all JNI entry points.
-keep class com.github.tfox.flutter_vless.** { *; }
-keep class libv2ray.** { *; }
-keep class xray.** { *; }

# ── Flutter / Platform Channels ───────────────────────────────────────────────
# io.flutter.** already includes embedding and plugin subpackages.
-keep class io.flutter.** { *; }

# ── Google Mobile Ads (AdMob) ─────────────────────────────────────────────────
-keep class com.google.android.gms.ads.** { *; }
-dontwarn com.google.android.gms.ads.**

# ── General Android / Kotlin ──────────────────────────────────────────────────
-keepattributes *Annotation*
-keepattributes SourceFile,LineNumberTable
-keep class kotlin.Metadata { *; }

# Strip debug logging in release builds
-assumenosideeffects class android.util.Log {
    public static boolean isLoggable(java.lang.String, int);
    public static int v(...);
    public static int d(...);
    public static int i(...);
}

# ── Google Play Core (Missing R8 Rules) ───────────────────────────────────────
-dontwarn com.google.android.play.core.splitcompat.SplitCompatApplication
-dontwarn com.google.android.play.core.splitinstall.SplitInstallException
-dontwarn com.google.android.play.core.splitinstall.SplitInstallManager
-dontwarn com.google.android.play.core.splitinstall.SplitInstallManagerFactory
-dontwarn com.google.android.play.core.splitinstall.SplitInstallRequest$Builder
-dontwarn com.google.android.play.core.splitinstall.SplitInstallRequest
-dontwarn com.google.android.play.core.splitinstall.SplitInstallSessionState
-dontwarn com.google.android.play.core.splitinstall.SplitInstallStateUpdatedListener
-dontwarn com.google.android.play.core.tasks.OnFailureListener
-dontwarn com.google.android.play.core.tasks.OnSuccessListener
-dontwarn com.google.android.play.core.tasks.Task
