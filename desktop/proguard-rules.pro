# MaxStream desktop — ProGuard rules.
# Compose ships its own default rules (auto-added by the Gradle plugin); this
# file only covers the non-Compose libraries, which are reflection/JNI heavy.

# --- Keep attributes needed for Kotlin/Compose/reflection ---------------------
-keepattributes *Annotation*, Signature, InnerClasses, EnclosingMethod
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile

# --- Entry point --------------------------------------------------------------
-keep class com.maxstream.app.MainKt {
    public static void main(java.lang.String[]);
}

# --- libmpv JNA bindings (native method names must survive obfuscation) -------
# JNA resolves interface methods and Structure field names by reflection.
-keep interface com.maxstream.app.player.MpvLibrary { *; }
-keep class com.maxstream.app.player.MpvLibrary { *; }
-keep interface com.maxstream.app.player.MpvRenderUpdateCallback { *; }
-keep class com.maxstream.app.player.MpvRenderParam { *; }
-keep class com.maxstream.app.player.MpvVideoRenderer { *; }
-keep class com.maxstream.app.player.PlayerController { *; }
-keep class com.maxstream.app.player.MpvRuntime { *; }
-keep class com.sun.jna.** { *; }
-keepclassmembers class * extends com.sun.jna.* { *; }
-dontwarn com.sun.jna.**

# OkHttp picks its platform (Conscrypt/BouncyCastle/OpenJSSE) via Class.forName.
-keep class okhttp3.internal.platform.** { *; }

# --- OkHttp / Okio (network stack) -------------------------------------------
-keep class okhttp3.** { *; }
-keep interface okhttp3.** { *; }
-keep class okio.** { *; }
-dontwarn okhttp3.**
-dontwarn okio.**
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**

# --- Coil 3 (async image loading, coroutine + factory based) ------------------
-keep class coil3.** { *; }
-keep interface coil3.** { *; }
-dontwarn coil3.**

# --- org.json (bundled, no Android version present) ---------------------------
-keep class org.json.** { *; }
-dontwarn org.json.**

# --- Kotlin / coroutines ------------------------------------------------------
-keep class kotlinx.coroutines.** { *; }
-keepclassmembers class kotlinx.coroutines.** {
    volatile <fields>;
}
-keep class kotlinx.coroutines.internal.MainDispatcherFactory { *; }
-keep class kotlinx.coroutines.CoroutineExceptionHandler { *; }
-dontwarn kotlinx.coroutines.**
-dontwarn kotlin.**
-dontwarn org.jetbrains.annotations.**

# --- Enums (ProGuard can strip the ACC_ENUM flag / synthetic members) ---------
# Without these, Enum.valueOf reports "<class> is not an enum class".
-keepclassmembers enum * {
    public static **[] values();
    public static ** valueOf(java.lang.String);
}
-keepclassmembers class * extends java.lang.Enum {
    <fields>;
}
-keep class * extends java.lang.Enum { *; }

# --- General: don't warn about optional/absent JVM-only references ------------
-dontwarn java.awt.**
-dontwarn javax.**
