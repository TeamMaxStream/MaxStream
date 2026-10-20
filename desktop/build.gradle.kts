import org.jetbrains.compose.desktop.application.dsl.TargetFormat
import java.io.File
import java.net.URI
import java.util.zip.ZipFile

plugins {
    kotlin("jvm") version "2.2.20"
    id("org.jetbrains.kotlin.plugin.compose") version "2.2.20"
    id("org.jetbrains.compose") version "1.8.2"
}

group = "com.maxstream"
// Shared product version across the phone, TV, and desktop apps. Keep the tag,
// pubspec.yaml, android/tvapp/build.gradle.kts, and AppConfig.APP_VERSION in
// sync; the release job in .github/workflows/build.yml enforces it.
version = "1.7.0"

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

    // Playback engine: libmpv via a tiny JNA binding (MpvLibrary /
    // PlayerController). The native library is bundled by syncMpvRuntime.
    implementation("net.java.dev.jna:jna:5.14.0")

    // Async image loading for TMDB posters/backdrops (Coil 3 = KMP/desktop).
    // Pin to 3.2.x: newer Coil ships kotlin-stdlib 2.4+ metadata, which the
    // Kotlin 2.2 compiler here cannot read.
    implementation("io.coil-kt.coil3:coil-compose:3.2.0")
    implementation("io.coil-kt.coil3:coil-network-okhttp:3.2.0")

    // Unit tests (kotlin.test on the default JUnit 4 runner — no extra config).
    testImplementation(kotlin("test"))
}

// libmpv is a single self-contained native library with all demuxers, codecs,
// HLS/DASH support and the GPU renderer compiled in. The official LGPL Windows
// build is pinned so installers are reproducible; CI downloads it once and
// Gradle caches the archive under ~/.gradle/caches.
//
// Override for a local build:
//   gradlew :desktop:syncMpvRuntime -PmpvLib="D:\path\to\libmpv-2.dll"
// On Linux/macOS development builds the task is skipped and MpvRuntime falls
// back to the system libmpv; package with -PmpvLib=... to ship it.
val mpvVersion = "0.41.0-dev-g6a262d11f"
val mpvArchiveUrl =
    "https://github.com/mpv-player/mpv/releases/download/git-release/" +
        "libmpv-v0.41.0-dev-g6a262d11f-39135297726-x86_64-w64-mingw32-lgpl.zip"
val mpvSource = providers.gradleProperty("mpvLib")
val mpvResourceRoot = layout.buildDirectory.dir("generated/mpv-resources")
val mpvResourceDir = mpvResourceRoot.map { it.dir("mpv") }

sourceSets["main"].resources.srcDir(mpvResourceRoot)

tasks.register("syncMpvRuntime") {
    group = "maxstream"
    description = "Bundles libmpv into the desktop app resources."
    inputs.property("mpvVersion", mpvVersion)
    inputs.property("mpvLib", mpvSource.orElse(""))
    outputs.dir(mpvResourceRoot)

    doLast {
        val out = mpvResourceDir.get().asFile
        out.deleteRecursively()
        out.mkdirs()

        val custom = mpvSource.orNull?.takeIf { it.isNotBlank() }?.let(::File)
        val isWindows = System.getProperty("os.name").startsWith("Windows", ignoreCase = true)
        val copied = mutableListOf<String>()

        if (custom != null) {
            require(custom.isFile) { "mpvLib does not point at a file: $custom" }
            val name = if (isWindows) "libmpv-2.dll" else custom.name
            custom.copyTo(File(out, name), overwrite = true)
            copied.add(name)
        } else if (isWindows) {
            val cacheDir = File(gradle.gradleUserHomeDir, "caches/maxstream-mpv/$mpvVersion")
            val archive = File(cacheDir, "libmpv.zip")
            if (!archive.isFile || archive.length() < 1_000_000L) {
                cacheDir.mkdirs()
                println("syncMpvRuntime: downloading $mpvArchiveUrl")
                URI(mpvArchiveUrl).toURL().openStream().use { input ->
                    archive.outputStream().use { output -> input.copyTo(output) }
                }
            }
            ZipFile(archive).use { zip ->
                for (entryName in listOf("libmpv-2.dll", "LICENSE.LGPL")) {
                    val entry = zip.getEntry(entryName)
                        ?: throw GradleException("$archive is missing $entryName")
                    zip.getInputStream(entry).use { input ->
                        File(out, entryName).outputStream().use { output -> input.copyTo(output) }
                    }
                    copied.add(entryName)
                }
            }
        } else {
            logger.lifecycle(
                "syncMpvRuntime: skipped on non-Windows host (system libmpv is used for " +
                    "development). Pass -PmpvLib=/path/to/libmpv.so.2 to bundle one.",
            )
            return@doLast
        }

        val dll = copied.firstOrNull { it.endsWith(".dll") || it.contains(".so") || it.endsWith(".dylib") }
        val version = if (dll != null) "$mpvVersion:${File(out, dll).length()}" else mpvVersion
        File(out, "VERSION.txt").writeText(version)
        val names = copied.sorted()
        File(out, "FILES.txt").writeText(names.joinToString("\n"))
        val mb = names.sumOf { File(out, it).length() } / (1024.0 * 1024.0)
        println(
            "syncMpvRuntime: bundled ${names.size} files (${"%.1f".format(mb)} MB) " +
                "into resources/mpv",
        )
    }
}
// Ensure the native library is in place before resources are packaged.
tasks.named("processResources") { dependsOn("syncMpvRuntime") }

// ProGuard: shrinks + obfuscates the JVM code on the release build type.
// CI must use `packageReleaseMsi` (not `packageMsi`): the default build type
// skips this block and ships the whole ~37 MB material-icons-extended jar.
compose.desktop {
    application {
        buildTypes {
            release {
                proguard {
                    isEnabled.set(true)
                    obfuscate.set(true)
                    // Shrink (drop unused code) is on by default; code *optimization*
                    // is off because JNA/OkHttp rely on reflection.
                    optimize.set(false)
                    version.set("7.4.2")
                    configurationFiles.from(project.files("proguard-rules.pro"))
                }
            }
        }
    }
}

// Promotes the packaged app to the user's Desktop (shortcut) and launches it.
// Run after a successful packageReleaseMsi / manual MSI install:
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
            ?: throw GradleException("MaxStream.exe not found after install. Run packageReleaseMsi (or the MSI) first.")
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
            // MSI is the reliable silent-update payload; EXE gives the manually
            // uploaded MaxStream-Dex.exe an installer to run. Both package the
            // full app image (launcher + runtime + jars + libmpv).
            targetFormats(TargetFormat.Msi, TargetFormat.Exe, TargetFormat.Dmg, TargetFormat.Deb)
            packageName = "MaxStream"
            // Must be MAJOR>0 for the macOS Dmg packager (0.1.0 is rejected).
            packageVersion = "1.7.0"
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