# PaladinVPN ProGuard / R8 Rules
# ==============================================================================
# These rules prevent R8 from stripping classes and methods that are accessed
# via JNI (Java Native Interface) or reflection, which would cause
# UnsatisfiedLinkError / ClassNotFoundException at runtime.

# ── AmneziaWG Native Backend (JNI) ────────────────────────────────────────────
# The wireguard_flutter plugin uses org.amnezia.awg for all tunnel operations.
# These classes are loaded via JNI — stripping them will crash the VPN.
-keep class org.amnezia.awg.backend.** { *; }
-keep class org.amnezia.awg.crypto.** { *; }
-keep class org.amnezia.awg.config.** { *; }
-keep class com.wireguard.** { *; }

# ── Kotlin Coroutines (used by wireguard_flutter plugin) ──────────────────────
-keepnames class kotlinx.coroutines.internal.MainDispatcherFactory {}
-keepnames class kotlinx.coroutines.CoroutineExceptionHandler {}

# ── Flutter / Platform Channels ───────────────────────────────────────────────
-keep class io.flutter.** { *; }
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugin.** { *; }

# ── Google Mobile Ads (AdMob) ─────────────────────────────────────────────────
-keep class com.google.android.gms.ads.** { *; }
-dontwarn com.google.android.gms.ads.**

# ── Klaxon JSON parser (used by wireguard_flutter plugin) ─────────────────────
-keep class com.beust.klaxon.** { *; }

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
