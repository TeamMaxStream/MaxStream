import org.jetbrains.compose.desktop.application.dsl.TargetFormat
import java.io.File

plugins {
    kotlin("jvm") version "2.2.20"
    id("org.jetbrains.kotlin.plugin.compose") version "2.2.20"
    id("org.jetbrains.compose") version "1.8.2"
}

group = "com.maxstream"
// Keep in sync with nativeDistributions.packageVersion below (they drifted:
// gradle said 0.1.0 while the installer said 1.0.1).
version = "1.0.1"

// Windows laptop app — its own desktop UX. Shares the com.maxstream.app package
// with the TV/mobile clients but does NOT use Google services (unavailable on
// desktop); the data layer is a swappable interface so a real backend (the same
// REST API the phone/Chromecast clients use) can be wired in later.
kotlin {
    jvmToolchain(17)
}

// Generated Res accessors for src/main/composeResources (replaces the
// deprecated painterResource("file") string API).
compose.resources {
    packageOfResClass = "com.maxstream.app.resources"
    // Default `auto` skips codegen in single-target JVM projects.
    generateResClass = always
}

java {
    toolchain {
        languageVersion = JavaLanguageVersion.of(17)
    }
}

dependencies {
    implementation(compose.desktop.currentOs)
    implementation(compose.material3)
    implementation(compose.materialIconsExtended)
    implementation(compose.ui)
    implementation(compose.foundation)
    implementation(compose.runtime)
    // Runtime for the generated Res accessors (compose.resources codegen).
    implementation("org.jetbrains.compose.components:components-resources:1.8.2")

    // Stream extraction (shared with the TV app): OkHttp + org.json.
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("org.json:json:20240303")

    // Coroutines incl. Swing (Dispatchers.Main) for the shared extractors.
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-swing:1.9.0")

    // Playback engine (VLCJ — requires libvlc from the VLC desktop install).
    implementation("uk.co.caprica:vlcj:4.8.3")

    // Async image loading for TMDB posters/backdrops (Coil 3 = KMP/desktop).
    // Pin to 3.2.x: newer Coil ships kotlin-stdlib 2.4+ metadata, which the
    // Kotlin 2.2 compiler here cannot read.
    implementation("io.coil-kt.coil3:coil-compose:3.2.0")
    implementation("io.coil-kt.coil3:coil-network-okhttp:3.2.0")

    // Unit tests (kotlin.test on the default JUnit 4 runner — no extra config).
    testImplementation(kotlin("test"))
}

// Copies the local VLC runtime (libvlc + plugins) into the app resources so the
// packaged app plays video without a separate VLC install. Overridable with
//   gradlew :desktop:syncVlcRuntime -PvlcSource="D:\path\to\VLC"
// Skips locale/skins/exes (translations & GUI — irrelevant to embedded playback).
val vlcSourceDir = providers.gradleProperty("vlcSource")
    .orElse("C:\\Program Files\\VideoLAN\\VLC")
val allowMissingVlc = providers.gradleProperty("allowMissingVlc").map { it == "true" }.orElse(false)
tasks.register<Sync>("syncVlcRuntime") {
    group = "maxstream"
    description = "Bundles the local VLC runtime (libvlc + plugins) into app resources."
    val src = File(vlcSourceDir.get())
    from(src) {
        include("libvlc.dll", "libvlccore.dll")
        include("plugins/**", "lua/**", "hrtfs/**")
    }
    into(layout.projectDirectory.dir("src/main/resources/vlc"))
    doFirst {
        if (!src.exists()) {
            val isWindows = System.getProperty("os.name").startsWith("Windows", ignoreCase = true)
            if (isWindows && !allowMissingVlc.get()) {
                // Previously a silent `logger.warn` — the MSI then shipped with an
                // empty player and no VLC installed on the target machine.
                throw GradleException(
                    "VLC not found at $src — refusing to build without a bundled player. " +
                        "Install VLC, set -PvlcSource=\"D:\\path\\to\\VLC\", or pass " +
                        "-PallowMissingVlc=true to package deliberately without it.",
                )
            }
            logger.warn("VLC source not found at $src — bundled player will be empty (non-Windows host; app falls back to installed VLC).")
        }
    }
    doLast {
        val outDir = layout.projectDirectory.dir("src/main/resources/vlc").asFile
        val core = File(src, "libvlc.dll")
        File(outDir, "VERSION.txt").writeText(if (core.exists()) "${core.length()}:${core.lastModified()}" else "missing")
        // Manifest of every bundled file so VlcRuntime can extract them from the JAR.
        val names = outDir.walkTopDown()
            .filter { it.isFile && it.name != "FILES.txt" }
            .map { it.relativeTo(outDir).invariantSeparatorsPath }
            .sorted()
            .toList()
        File(outDir, "FILES.txt").writeText(names.joinToString("\n"))
        val pluginsMb = names.filter { it.startsWith("plugins/") }
            .sumOf { File(outDir, it).length() } / (1024.0 * 1024.0)
        println("syncVlcRuntime: bundled ${names.size} files (${ "%.1f".format(pluginsMb) } MB plugins) into resources/vlc")
    }
}
// Ensure the bundle is refreshed before resources are packaged into the JAR/MSI.
tasks.named("processResources") { dependsOn("syncVlcRuntime") }

// ProGuard: shrinks + obfuscates the JVM code on the release build type. Build
// with `packageReleaseMsi` (not `packageMsi`) to get the minified installer.
compose.desktop {
    application {
        buildTypes {
            release {
                proguard {
                    isEnabled.set(true)
                    obfuscate.set(true)
                    // Shrink (drop unused code) is on by default; code *optimization*
                    // is off because vlcj/JNA/OkHttp rely on reflection.
                    optimize.set(false)
                    version.set("7.4.2")
                    configurationFiles.from(project.files("proguard-rules.pro"))
                }
            }
        }
    }
}

// Promotes the packaged app to the user's Desktop (shortcut) and launches it.
// Run after a successful `packageMsi` / manual MSI install:
//   gradlew desktop:promoteAndLaunch
tasks.register<DefaultTask>("promoteAndLaunch") {
    group = "maxstream"
    description = "Places a MaxStream shortcut on the Desktop and launches the app."
    doLast {
        val exeCandidates = listOf(
            "C:\\Program Files\\MaxStream\\MaxStream.exe",
            System.getenv("LOCALAPPDATA") + "\\Programs\\MaxStream\\MaxStream.exe",
        )
        val exe = exeCandidates.firstOrNull { File(it).exists() }
            ?: throw GradleException("MaxStream.exe not found after install. Run packageMsi (or the MSI) first.")
        val script = layout.projectDirectory.file("..\\scripts\\desktop-shortcut.ps1").asFile
        require(script.exists()) { "Missing scripts/desktop-shortcut.ps1 — required by promoteAndLaunch" }
        val proc = ProcessBuilder(
            "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", script.absolutePath, exe,
        )
            .directory(layout.projectDirectory.asFile)
            .redirectErrorStream(true)
            .start()
        val output = proc.inputStream.bufferedReader().readText()
        proc.waitFor()
        if (proc.exitValue() != 0) throw GradleException("Shortcut script failed:\n$output")
        println("Shortcut placed on Desktop and app launched: $exe")
    }
}

compose.desktop {
    application {
        mainClass = "com.maxstream.app.MainKt"
        nativeDistributions {
            targetFormats(TargetFormat.Msi, TargetFormat.Dmg, TargetFormat.Deb)
            packageName = "MaxStream"
            // Must be MAJOR>0 for the macOS Dmg packager (0.1.0 is rejected).
            packageVersion = "1.0.1"
            description = "MaxStream for Windows — desktop catalog & playback client"
            vendor = "MaxStream"
            // Compose only auto-detects JDK modules from *dependencies*; our own
            // PlayerScreen uses java.net.http.HttpClient (subtitle fetch), which
            // would otherwise be missing from the jlink image and throw
            // NoClassDefFoundError on Play. Add it explicitly.
            modules("java.net.http")
            windows {
                // Start Menu + Desktop/launch shortcuts so the app is easy to find.
                menu = true
                shortcut = true
                menuGroup = "MaxStream"
                upgradeUuid = "d07b3db8-2e2a-4a27-8e0f-1f0dc37f1f4c"
                // App icon shown for the installed exe / taskbar / Start Menu
                // (app_icon.png = M mark only; maxstream_logo.png is the wordmark).
                iconFile.set(layout.projectDirectory.file("icon.ico"))
            }
        }
    }
}