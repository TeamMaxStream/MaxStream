package com.maxstream.app.player

import com.sun.jna.Library
import com.sun.jna.Native
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption

/**
 * Locates libmpv, extracting the copy bundled in the application JAR on first
 * launch. This is one self-contained DLL/so — mpv's demuxers, decoders and
 * HLS/DASH support are compiled into it.
 *
 * The bundle lives under `src/main/resources/mpv` in development builds, but
 * Gradle normally writes it to `build/generated/mpv-resources` (see
 * `syncMpvRuntime`). `FILES.txt` lists every file to extract.
 */
object MpvRuntime {
    private const val RESOURCE_ROOT = "mpv"
    private const val DIR_PROP = "maxstream.mpv.dir"

    @Volatile
    private var initialized = false

    private val isWindows: Boolean
        get() = System.getProperty("os.name").startsWith("Windows", ignoreCase = true)

    private val libraryFileNames: List<String>
        get() = when {
            isWindows -> listOf("libmpv-2.dll", "mpv-2.dll", "libmpv.dll")
            System.getProperty("os.name").startsWith("Mac", ignoreCase = true) ->
                listOf("libmpv.2.dylib", "libmpv.dylib")
            else -> listOf("libmpv.so.2", "libmpv.so", "libmpv.so.1")
        }

    /**
     * Extracts the bundled runtime (if needed) and makes its directory available
     * to JNA. Safe to call repeatedly and safe when no runtime was bundled (Linux
     * development builds fall back to the system libmpv).
     */
    @Synchronized
    fun ensure() {
        if (initialized) return
        initialized = true
        // libmpv's API is UTF-8 on every platform. JNA otherwise uses the JVM's
        // platform encoding, which is not UTF-8 on Windows JDK 17.
        System.setProperty("jna.encoding", "UTF-8")

        val version = readResource("$RESOURCE_ROOT/VERSION.txt")?.trim().orEmpty()
        val files = readResource("$RESOURCE_ROOT/FILES.txt")
            ?.lineSequence()
            ?.map { it.trim().replace('\\', '/') }
            ?.filter { it.isNotEmpty() }
            ?.toList()
            .orEmpty()
        if (files.isEmpty()) return

        val base = System.getenv("LOCALAPPDATA") ?: System.getProperty("user.home")
        val target = File(base, "MaxStream${File.separator}mpv")
        val marker = File(target, "VERSION.txt")
        val want = version.ifBlank { "bundled" }
        val installed = if (marker.exists()) marker.readText().trim() else ""

        val bundled = files.firstOrNull { isLibraryName(it) }
        if (bundled != null && (!File(target, bundled).exists() || installed != want)) {
            extract(target, files, want, marker)
        }

        val dir = System.getProperty(DIR_PROP)?.let(::File)
            ?.takeIf { it.isDirectory }
            ?: target.takeIf { dir -> files.any { File(dir, it).exists() } }
        if (dir != null) {
            System.setProperty(DIR_PROP, dir.absolutePath)
            val existing = System.getProperty("jna.library.path")
            System.setProperty(
                "jna.library.path",
                if (existing.isNullOrBlank()) dir.absolutePath
                else dir.absolutePath + File.pathSeparator + existing,
            )
        }
    }

    /**
     * Loads libmpv from the extracted bundle, an explicit
     * `-Dmaxstream.mpv.lib=...`, or the system library (Linux/macOS development).
     */
    internal fun load(): MpvLibrary {
        ensure()
        val options = mapOf<String, Any>(Library.OPTION_STRING_ENCODING to "UTF-8")
        val failures = mutableListOf<String>()

        val explicit = System.getProperty("maxstream.mpv.lib")
            ?.takeIf { it.isNotBlank() }
            ?.let(::File)
        val bundled = bundledLibrary()
        for (candidate in listOfNotNull(explicit, bundled)) {
            runCatching { Native.load(candidate.absolutePath, MpvLibrary::class.java, options) }
                .onSuccess { return it }
                .onFailure { failures += "${candidate.absolutePath}: ${it.message}" }
        }

        // Development fallback: a system-installed libmpv (not shipped on Windows).
        val names = if (isWindows) {
            listOf("libmpv-2", "mpv-2", "libmpv")
        } else {
            libraryFileNames + "mpv"
        }
        for (name in names) {
            runCatching { Native.load(name, MpvLibrary::class.java, options) }
                .onSuccess { return it }
                .onFailure { failures += "$name: ${it.message}" }
        }

        val detail = failures.joinToString("\n") { "  - $it" }
        throw MpvException(
            "libmpv could not be loaded. Install libmpv or build with the bundled runtime.\n$detail",
        )
    }

    /** Directory the bundled runtime was extracted to, if present. */
    val bundledDir: File?
        get() = System.getProperty(DIR_PROP)?.let(::File)?.takeIf { it.isDirectory }

    private fun bundledLibrary(): File? {
        val dir = bundledDir ?: return null
        return dir.listFiles()
            ?.firstOrNull { it.isFile && isLibraryName(it.name) }
    }

    private fun isLibraryName(name: String): Boolean {
        val n = name.substringAfterLast('/')
        return (n.startsWith("libmpv") || n.startsWith("mpv-")) &&
            (n.endsWith(".dll") || n.endsWith(".dylib") || n.contains(".so"))
    }

    private fun extract(target: File, files: List<String>, version: String, marker: File) {
        val loader = javaClass.classLoader
        try {
            for (rel in files) {
                val dest = File(target, rel)
                dest.parentFile?.mkdirs()
                val input = loader.getResourceAsStream("$RESOURCE_ROOT/$rel") ?: continue
                input.use { stream ->
                    Files.copy(stream, dest.toPath(), StandardCopyOption.REPLACE_EXISTING)
                }
            }
            marker.parentFile?.mkdirs()
            marker.writeText(version)
        } catch (t: Throwable) {
            System.err.println("MpvRuntime: could not extract bundled libmpv: $t")
        }
    }

    private fun readResource(name: String): String? =
        javaClass.classLoader.getResourceAsStream(name)
            ?.use { it.readBytes().decodeToString() }
}
