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
    id("com.android.application") version "9.0.1" apply false
}

include(":app")
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
