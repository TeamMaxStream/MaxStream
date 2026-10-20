package com.maxstream.app.player

import com.sun.jna.Memory
import com.sun.jna.Native
import com.sun.jna.Pointer
import com.sun.jna.StringArray
import java.util.Locale

/**
 * Thin wrapper around libmpv so the UI never touches native types.
 *
 * Video is decoded and converted to packed RGB by mpv's software render API.
 * [videoFrame] is the latest frame; Compose paints it like any other image, so
 * the player and the mini-player can live entirely inside the Compose scene
 * (no native child window, no interop blending, no z-order surprises).
 *
 * Control commands stay on the UI thread; rendering runs on its own thread as
 * required by libmpv's render API.
 */
class PlayerController(
    /** Test/automation overrides applied after the production defaults. */
    private val extraOptions: Map<String, String> = emptyMap(),
) {
    private val lock = Any()
    private val cLibrary: CLibrary? by lazy {
        if (System.getProperty("os.name").startsWith("Windows", ignoreCase = true)) {
            null
        } else {
            runCatching { Native.load("c", CLibrary::class.java) }.getOrNull()
        }
    }
    private var library: MpvLibrary? = null
    private var handle: Pointer? = null
    private var eventThread: Thread? = null

    @Volatile
    private var renderTarget: MpvVideoRenderer? = null

    @Volatile
    private var viewportWidth = 0

    @Volatile
    private var viewportHeight = 0

    @Volatile
    private var eventLoopRunning = false

    @Volatile
    private var loaded = false

    @Volatile
    private var released = false

    private var desiredVolume = 80
    private var desiredMute = false

    private data class LoadRequest(
        val url: String,
        val referer: String?,
        val userAgent: String?,
        val origin: String?,
    )

    fun play(url: String, referer: String?, userAgent: String?, origin: String?) {
        synchronized(lock) {
            check(!released) { "Player has been released" }
            ensureInitializedLocked()
            loadLocked(LoadRequest(url, referer, userAgent, origin))
        }
    }

    /** True once media has been handed to mpv (cleared by [stop]/[release]). */
    fun hasMedia(): Boolean = loaded && synchronized(lock) { handle != null }

    /** Latest decoded frame, or null until video starts (or after [stop]). */
    val videoFrame: VideoFrame?
        get() = renderTarget?.frame

    /**
     * Output size in physical pixels. Called from the UI as the player window
     * (or mini-player preview) is laid out. Kept as a field so a renderer
     * created later immediately uses the current size.
     */
    fun setVideoViewport(width: Int, height: Int) {
        viewportWidth = width
        viewportHeight = height
        renderTarget?.setViewport(width, height)
    }

    val isPlaying: Boolean
        get() = synchronized(lock) {
            val ctx = handle ?: return false
            if (!loaded) return false
            !flagLocked(ctx, "pause") &&
                !flagLocked(ctx, "idle-active") &&
                !flagLocked(ctx, "eof-reached")
        }

    fun time(): Long = synchronized(lock) {
        val ctx = handle ?: return 0L
        (doubleLocked(ctx, "time-pos") ?: 0.0)
            .takeIf { it.isFinite() && it >= 0.0 }
            ?.times(1000.0)?.toLong() ?: 0L
    }

    fun length(): Long = synchronized(lock) {
        val ctx = handle ?: return 0L
        (doubleLocked(ctx, "duration") ?: 0.0)
            .takeIf { it.isFinite() && it > 0.0 }
            ?.times(1000.0)?.toLong() ?: 0L
    }

    fun playControl() {
        synchronized(lock) {
            val ctx = handle ?: return
            if (flagLocked(ctx, "eof-reached")) {
                runCatching { commandLocked("seek", "0", "absolute+exact") }
            }
            propertyLocked("pause", "no")
        }
    }

    fun pause() {
        synchronized(lock) {
            propertyLocked("pause", "yes")
        }
    }

    fun stop() {
        synchronized(lock) {
            loaded = false
            val ctx = handle ?: return
            runCatching { commandLocked("stop") }
            renderTarget?.clearFrame()
        }
    }

    fun setTime(ms: Long) {
        synchronized(lock) {
            val ctx = handle ?: return
            if (!loaded) return
            val seconds = (ms.coerceAtLeast(0L) / 1000.0)
            runCatching {
                commandLocked("seek", "%.3f".format(Locale.ROOT, seconds), "absolute+exact")
            }
        }
    }

    fun setPosition(frac: Float) {
        synchronized(lock) {
            val ctx = handle ?: return
            if (!loaded) return
            val percent = (frac.coerceIn(0f, 1f) * 100.0)
            runCatching {
                commandLocked(
                    "seek",
                    "%.3f".format(Locale.ROOT, percent),
                    "absolute-percent+exact",
                )
            }
        }
    }

    fun setVolume(pct: Int) {
        synchronized(lock) {
            desiredVolume = pct.coerceIn(0, 100)
            propertyLocked("volume", desiredVolume.toString())
        }
    }

    fun setMute(muted: Boolean) {
        synchronized(lock) {
            desiredMute = muted
            propertyLocked("mute", if (muted) "yes" else "no")
        }
    }

    /** Audio tracks mpv exposes (id + display name), or empty before parsing. */
    fun audioTrackDescriptions(): List<Pair<Int, String>> = synchronized(lock) {
        val ctx = handle ?: return emptyList()
        val count = longLocked(ctx, "track-list/count") ?: return emptyList()
        buildList {
            for (i in 0 until count.coerceIn(0L, 64L)) {
                if (stringLocked(ctx, "track-list/$i/type") != "audio") continue
                val id = longLocked(ctx, "track-list/$i/id") ?: continue
                val title = stringLocked(ctx, "track-list/$i/title").orEmpty().trim()
                val lang = stringLocked(ctx, "track-list/$i/lang").orEmpty().trim()
                val languageName = if (lang.isBlank() || lang.equals("und", true)) {
                    ""
                } else {
                    runCatching {
                        Locale.forLanguageTag(lang).getDisplayLanguage(Locale.ENGLISH)
                    }.getOrDefault("")
                }
                val parts = listOf(title, languageName, lang)
                    .filter { it.isNotBlank() }
                    .distinctBy { it.lowercase() }
                val label = parts.joinToString(" • ").ifBlank { "Track ${id.toInt()}" }
                add(id.toInt() to label)
            }
        }
    }

    /** Currently selected audio track id (-1 = automatic/none). */
    fun currentAudioTrack(): Int = synchronized(lock) {
        val ctx = handle ?: return -1
        val value = stringLocked(ctx, "aid") ?: return -1
        value.toIntOrNull() ?: -1
    }

    /** Selects an audio track by mpv id; -1/0 means automatic. */
    fun selectAudioTrack(id: Int) {
        synchronized(lock) {
            if (id <= 0) propertyLocked("aid", "auto")
            else propertyLocked("aid", id.toString())
        }
    }

    fun setSubtitleFile(path: String) {
        synchronized(lock) {
            runCatching { commandLocked("sub-add", path, "select") }
        }
    }

    /** Turns subtitles off without disturbing the selected audio track. */
    fun disableSubtitles() {
        synchronized(lock) { propertyLocked("sid", "no") }
    }

    fun togglePlayPause() {
        if (isPlaying) pause() else playControl()
    }

    /** Terminates libmpv. Called on sign-out (after [stop]) and window close. */
    fun release() {
        synchronized(lock) {
            released = true
            releaseLocked()
        }
    }

    /** Allows a released controller to be reused after a profile switch. */
    fun revive() {
        synchronized(lock) { released = false }
    }

    // ── libmpv plumbing ────────────────────────────────────────────────────

    private fun ensureInitializedLocked() {
        if (handle != null) return

        // libmpv aborts mpv_create() with a NULL handle when LC_NUMERIC is not
        // "C". JVMs inherit the user's locale (C.UTF-8 here), so pin it first.
        cLibrary?.let { runCatching { it.setlocale(1, "C") } }

        val lib = MpvRuntime.load()
        val ctx = lib.mpv_create() ?: throw MpvException("mpv_create() returned NULL")
        library = lib
        handle = ctx
        var renderer: MpvVideoRenderer? = null

        try {
            optionLocked("config", "no")
            optionLocked("terminal", "no")
            optionLocked("input-default-bindings", "no")
            optionLocked("input-builtin-bindings", "no")
            optionLocked("input-vo-keyboard", "no")
            optionLocked("input-cursor", "no")
            optionLocked("osc", "no")
            optionLocked("osd-level", "0")
            optionLocked("osd-bar", "no")
            optionLocked("force-window", "no")
            optionLocked("keep-open", "no")
            optionLocked("idle", "yes")
            optionLocked("audio-client-name", "MaxStream")
            optionLocked("title", "MaxStream")
            optionLocked("hwdec", "auto-safe")
            optionLocked("cache", "yes")
            optionLocked("demuxer-max-bytes", "256MiB")
            optionLocked("demuxer-max-back-bytes", "64MiB")
            optionLocked("network-timeout", "30")
            optionLocked("sub-auto", "no")
            optionLocked("audio-file-auto", "no")
            optionLocked("ytdl", "no")
            // The software render API owns the video output; do not let mpv
            // create a window or pump frames through a GPU context.
            optionLocked("vo", "libmpv")
            optionLocked("sw-fast", "yes")
            // The UI paints at its own pace; mpv must not block the render
            // thread waiting for a display's vsync.
            optionLocked("video-timing-offset", "0")
            extraOptions.forEach { (name, value) -> optionLocked(name, value) }

            val video = MpvVideoRenderer(lib, ctx)
            renderer = video
            video.create()
            video.setViewport(viewportWidth, viewportHeight)

            val rc = lib.mpv_initialize(ctx)
            if (rc < 0) throw MpvException("mpv_initialize failed: ${error(lib, rc)}")

            video.start()
            renderTarget = video
            applyAudioLocked(ctx)
            startEventLoopLocked(lib, ctx)
        } catch (t: Throwable) {
            runCatching { renderer?.stop() }
            if (renderTarget === renderer) renderTarget = null
            runCatching { lib.mpv_terminate_destroy(ctx) }
            library = null
            handle = null
            throw t
        }
    }

    private fun loadLocked(request: LoadRequest) {
        val ctx = handle ?: throw MpvException("mpv is not initialized")
        configureHeadersLocked(ctx, request.referer, request.userAgent, request.origin)
        val rc = commandLocked("loadfile", request.url, "replace")
        if (rc < 0) throw MpvException("mpv could not open the stream: ${error(library, rc)}")
        loaded = true
    }

    private fun configureHeadersLocked(
        ctx: Pointer,
        referer: String?,
        userAgent: String?,
        origin: String?,
    ) {
        propertyLocked("referrer", referer.orEmpty())
        propertyLocked("user-agent", userAgent.orEmpty())
        runCatching { commandLocked("change-list", "http-header-fields", "clr", "") }
        if (!origin.isNullOrBlank()) {
            runCatching {
                commandLocked("change-list", "http-header-fields", "append", "Origin: $origin")
            }
        }
    }

    private fun applyAudioLocked(ctx: Pointer) {
        propertyLocked("volume", desiredVolume.toString())
        propertyLocked("mute", if (desiredMute) "yes" else "no")
    }

    private fun startEventLoopLocked(lib: MpvLibrary, ctx: Pointer) {
        eventLoopRunning = true
        eventThread = Thread({
            while (eventLoopRunning) {
                val event = runCatching { lib.mpv_wait_event(ctx, 0.5) }.getOrNull()
                if (event == null) break
            }
        }, "maxstream-mpv-events").apply {
            isDaemon = true
            start()
        }
    }

    private fun releaseLocked() {
        loaded = false
        eventLoopRunning = false
        val lib = library
        val ctx = handle
        if (lib != null && ctx != null) {
            runCatching { lib.mpv_wakeup(ctx) }
        }
        // libmpv requires the render context to be destroyed before the core.
        runCatching { renderTarget?.stop() }
        renderTarget = null
        eventThread?.let { thread ->
            runCatching { thread.join(2_000) }
            if (thread.isAlive) {
                System.err.println("PlayerController: mpv event thread did not stop in time")
            }
        }
        eventThread = null
        if (lib != null && ctx != null) {
            runCatching { lib.mpv_terminate_destroy(ctx) }
        }
        handle = null
        library = null
    }

    private fun propertyLocked(name: String, value: String) {
        val lib = library ?: return
        val ctx = handle ?: return
        lib.mpv_set_property_string(ctx, name, value)
    }

    private fun optionLocked(name: String, value: String) {
        val lib = library ?: return
        val ctx = handle ?: return
        lib.mpv_set_option_string(ctx, name, value)
    }

    private fun commandLocked(vararg args: String): Int {
        val lib = library ?: return -1
        val ctx = handle ?: return -1
        val array = StringArray(args, "UTF-8")
        return lib.mpv_command(ctx, array)
    }

    private fun stringLocked(ctx: Pointer, name: String): String? {
        val lib = library ?: return null
        val pointer = lib.mpv_get_property_string(ctx, name) ?: return null
        return try {
            pointer.getString(0, "UTF-8")
        } finally {
            lib.mpv_free(pointer)
        }
    }

    private fun doubleLocked(ctx: Pointer, name: String): Double? {
        val lib = library ?: return null
        val mem = Memory(8)
        val rc = lib.mpv_get_property(ctx, name, MpvFormat.DOUBLE, mem)
        return if (rc >= 0) mem.getDouble(0) else null
    }

    private fun longLocked(ctx: Pointer, name: String): Long? {
        val lib = library ?: return null
        val mem = Memory(8)
        val rc = lib.mpv_get_property(ctx, name, MpvFormat.INT64, mem)
        return if (rc >= 0) mem.getLong(0) else null
    }

    private fun flagLocked(ctx: Pointer, name: String): Boolean {
        val lib = library ?: return false
        val mem = Memory(4)
        val rc = lib.mpv_get_property(ctx, name, MpvFormat.FLAG, mem)
        return rc >= 0 && mem.getInt(0) != 0
    }

    private fun error(lib: MpvLibrary?, code: Int): String {
        if (lib == null) return "error $code"
        return runCatching { lib.mpv_error_string(code) }.getOrNull() ?: "error $code"
    }
}
