package com.maxstream.app.player

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.maxstream.app.data.WatchStateStore
import com.maxstream.app.data.model.MediaItem
import com.maxstream.app.data.model.PlayRequest
import com.maxstream.app.data.repository.TmdbRepository
import com.maxstream.app.stream.ResolvedStream
import java.nio.file.Files
import java.nio.file.Path
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/** What the mini-player shows, and what expanding it resumes. */
data class NowPlaying(
    val request: PlayRequest,
    val server: String,
    val quality: String,
    val local: Boolean,
)

/**
 * One libmpv session for the whole app. The full player and the mini-player are
 * two presentations of the same session, so backing out of [PlayerScreen] no
 * longer stops audio and re-opening it does not restart the stream.
 *
 * mpv control calls stay on the UI thread; disk/network work is dispatched to IO.
 */
object PlaybackSession {

    val controller: PlayerController by lazy { PlayerController() }

    var nowPlaying by mutableStateOf<NowPlaying?>(null)
        private set
    var minimized by mutableStateOf(false)
        private set

    /** Persisted between expanded/mini so volume does not jump on re-entry. */
    var volume by mutableStateOf(80)
    var muted by mutableStateOf(false)

    var streams: List<ResolvedStream> = emptyList()
        private set
    var selectedIndex: Int = -1
        private set

    private val mainScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val ioScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var saveJob: Job? = null
    private val subtitleFiles = mutableListOf<Path>()

    /**
     * True when the player screen for [request] can reattach to the live
     * session instead of resolving the title again.
     */
    fun isActiveFor(request: PlayRequest): Boolean {
        val current = nowPlaying ?: return false
        return current.request.itemId == request.itemId &&
            current.request.season == request.season &&
            current.request.episode == request.episode &&
            current.request.mediaType == request.mediaType &&
            current.request.localPath == request.localPath &&
            controller.hasMedia()
    }

    fun play(
        request: PlayRequest,
        url: String,
        referer: String?,
        userAgent: String?,
        origin: String?,
        server: String,
        quality: String,
        streamList: List<ResolvedStream>,
        selected: Int,
        local: Boolean,
    ) {
        val previous = nowPlaying
        if (previous != null && !sameEpisode(previous.request, request)) {
            saveProgressNow()
            clearSubtitles()
        }
        controller.setVolume(volume)
        controller.setMute(muted)
        controller.play(url, referer, userAgent, origin)
        nowPlaying = NowPlaying(request, server, quality, local)
        minimized = false
        streams = streamList
        selectedIndex = selected
        startSaveLoop()
    }

    /** Keeps the expand path's server/quality lists in sync with the player. */
    fun updateStreams(list: List<ResolvedStream>, selected: Int) {
        streams = list
        selectedIndex = selected
    }

    fun minimize() {
        if (nowPlaying != null && controller.hasMedia()) {
            saveProgressNow()
            minimized = true
        }
    }

    fun expand() {
        minimized = false
    }

    /** Called when the full player leaves composition: keep audio in the mini. */
    fun onScreenDetached() {
        if (nowPlaying != null && controller.hasMedia()) {
            saveProgressNow()
            minimized = true
        }
    }

    fun stop() {
        saveProgressNow()
        saveJob?.cancel()
        saveJob = null
        runCatching { controller.stop() }
        nowPlaying = null
        minimized = false
        streams = emptyList()
        selectedIndex = -1
        clearSubtitles()
    }

    fun trackSubtitle(path: String) {
        subtitleFiles.add(Path.of(path))
    }

    private fun sameEpisode(a: PlayRequest, b: PlayRequest): Boolean =
        a.itemId == b.itemId &&
            a.season == b.season &&
            a.episode == b.episode &&
            a.mediaType == b.mediaType

    private fun clearSubtitles() {
        subtitleFiles.forEach { path -> runCatching { Files.deleteIfExists(path) } }
        subtitleFiles.clear()
    }

    private fun startSaveLoop() {
        saveJob?.cancel()
        saveJob = mainScope.launch {
            while (isActive) {
                delay(10_000)
                // The expanded PlayerScreen saves every 10 s itself; only the
                // mini-player needs a background writer.
                if (minimized) saveProgressNow()
            }
        }
    }

    private fun saveProgressNow() {
        val current = nowPlaying ?: return
        if (!controller.hasMedia()) return
        val position = runCatching { controller.time() }.getOrDefault(0L)
        val length = runCatching { controller.length() }.getOrDefault(0L)
        if (position <= 0L || length <= 0L) return
        val item = MediaItem(
            id = current.request.itemId,
            mediaType = current.request.mediaType,
            title = current.request.title,
            overview = "",
            posterPath = current.request.posterPath,
        )
        // ioScope survives PlayerScreen disposal, so the last checkpoint lands.
        ioScope.launch {
            runCatching {
                TmdbRepository.saveProgress(
                    item,
                    current.request.season,
                    current.request.episode,
                    position,
                    length,
                )
            }.onFailure { e -> System.err.println("PlaybackSession: progress save failed: $e") }
        }
    }
}
