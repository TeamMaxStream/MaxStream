pluginManagement {
    val flutterSdkPath = run {
        val properties = java.util.Properties()
        file("local.properties").inputStream().use { properties.load(it) }
        val flutterSdkPath = properties.getProperty("flutter.sdk")
        require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
        flutterSdkPath
    }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.3.0"
    // Versions match Flutter 3.50's tested Android toolchain (Gradle 9.5.0,
    // AGP 9.3.1, KGP 2.4.20). Flutter's minimums are AGP 9.1.1 / KGP 2.4.10;
    // matching its template avoids both hard failures and support warnings.
    id("com.android.application") version "9.3.1" apply false
    id("com.android.library") version "9.3.1" apply false
    // Kotlin Gradle Plugin: required because built-in Kotlin is opted out of
    // (see gradle.properties).
    id("org.jetbrains.kotlin.android") version "2.4.20" apply false
}

include(":app")
// Stream extractor shared by the phone app and the native TV app. Always
// included (no native dependencies), so both builds compile the same sources.
include(":streamcore")
// TV app is a separate product flavor with heavy native deps (nextlib FFmpeg).
// Including it unconditionally makes *any* Gradle invocation (including
// `flutter build apk` for mobile) configure :tvapp and try to resolve
// nextlib-media3ext. If that artifact is temporarily unavailable (503) the
// mobile build fails with the same TV error. Conditionally include it:
// - Mobile CI sets EXCLUDE_TV=true / -PexcludeTv so only :app is configured.
// - Local & TV CI include it by default for normal development.
val excludeTv = providers.gradleProperty("excludeTv").isPresent
    || System.getenv("EXCLUDE_TV") == "true"
if (!excludeTv) {
    include(":tvapp")
}
