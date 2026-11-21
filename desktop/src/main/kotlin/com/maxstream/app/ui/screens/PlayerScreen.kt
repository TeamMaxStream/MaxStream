package com.maxstream.app.ui.screens

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import coil3.compose.AsyncImage
import com.maxstream.app.core.AppConfig
import com.maxstream.app.data.model.Episode
import com.maxstream.app.data.model.Season
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.VolumeDown
import androidx.compose.material.icons.automirrored.filled.VolumeOff
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.Audiotrack
import androidx.compose.material.icons.filled.ClosedCaption
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material.icons.filled.Fullscreen
import androidx.compose.material.icons.filled.FullscreenExit
import androidx.compose.material.icons.filled.HighQuality
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isCtrlPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.onPointerEvent
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.WindowPlacement
import androidx.compose.ui.window.WindowState
import com.maxstream.app.data.AppPrefs
import com.maxstream.app.data.WatchStateStore
import com.maxstream.app.data.model.MediaItem
import com.maxstream.app.data.model.PlayRequest
import com.maxstream.app.data.repository.MediaRepository
import com.maxstream.app.player.PlaybackSession
import com.maxstream.app.stream.FailedServer
import com.maxstream.app.stream.ResolvedAudioTrack
import com.maxstream.app.stream.ResolvedStream
import com.maxstream.app.stream.ResolvedSubtitle
import com.maxstream.app.stream.StreamResolver
import com.maxstream.app.stream.parseFailedServers
import com.maxstream.app.stream.parseStreams
import com.maxstream.app.stream.pickDefaultSubtitle
import com.maxstream.app.ui.components.PlayerSurface
import com.maxstream.app.ui.components.appFocusRing
import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.nio.file.Files
import java.nio.file.Path
import java.time.Duration
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Survives composition disposal so the final progress save actually runs —
 * `rememberCoroutineScope()` is cancelled before onDispose executes, which
 * silently dropped the last ≤10s of playback on every exit.
 */
private val teardownScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

/**
 * Desktop player with auto-hiding overlay controls:
 * - Space / Backspace toggle play-pause (focus stays on Compose, not native UI).
 * - F toggles window fullscreen; Esc leaves fullscreen first, then goes back.
 * - Controls stay visible while paused or while a menu is open; auto-hide
 *   ~1s while playing.
 * - Entering maximizes the window (unless already fullscreen); leaving
 *   restores the previous placement via Shell.
 */
@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
@Composable
fun PlayerScreen(
    request: PlayRequest,
    repository: MediaRepository,
    onBack: () -> Unit,
    windowState: WindowState? = null,
) {
    val controller = PlaybackSession.controller
    val scope = rememberCoroutineScope()
    val focusRequester = remember { FocusRequester() }
    val offline = request.localPath != null
    val isMovie = request.mediaType == "movie"
    val isSeries = request.mediaType == "tv"

    var streams by remember { mutableStateOf<List<ResolvedStream>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }
    var selectedIndex by remember { mutableIntStateOf(-1) }
    var failedServers by remember { mutableStateOf<List<FailedServer>>(emptyList()) }
    var resolvingAll by remember { mutableStateOf(false) }
    var currentSeason by remember { mutableIntStateOf(request.season) }
    var currentEpisode by remember { mutableIntStateOf(request.episode) }
    var activeSeason by remember { mutableIntStateOf(request.season) }
    var activeEpisode by remember { mutableIntStateOf(request.episode) }

    // Series seasons/episodes browser state (mirrors TV player's Episodes panel).
    var seasons by remember { mutableStateOf<List<com.maxstream.app.data.model.Season>>(emptyList()) }
    var menuSeason by remember { mutableIntStateOf(request.season) }
    var menuEpisodesCache by remember { mutableStateOf<Map<Int, List<com.maxstream.app.data.model.Episode>>>(emptyMap()) }
    var episodePanelOpen by remember { mutableStateOf(false) }
    var episodeMenuLoading by remember { mutableStateOf(false) }
    var seasonEpisodes by remember { mutableStateOf<List<com.maxstream.app.data.model.Episode>>(emptyList()) }
    var autoAdvancing by remember { mutableStateOf(false) }
    var endedHandled by remember { mutableStateOf(false) }

    // Next-episode preview (mobile-style bottom-right).
    var showNextPreview by remember { mutableStateOf(false) }
    var nextPreviewSeason by remember { mutableIntStateOf(0) }
    var nextPreviewEpisode by remember { mutableIntStateOf(0) }
    var nextPreviewName by remember { mutableStateOf("") }
    var nextPreviewStill by remember { mutableStateOf<String?>(null) }
    var nextPreviewCountdown by remember { mutableIntStateOf(0) }

    var selectedAudioLabel by remember { mutableStateOf<String?>(null) }
    // Per-server subtitle overrides (server name → subtitle). A server the user
    // explicitly configured in this session keeps that choice when re-opened.
    var subtitleOverrides by remember { mutableStateOf<Map<String, ResolvedSubtitle?>>(emptyMap()) }
    var activeSubtitleUrl by remember { mutableStateOf<String?>(null) }

    var positionMs by remember { mutableLongStateOf(0L) }
    var lengthMs by remember { mutableLongStateOf(0L) }
    var sliderFrac by remember { mutableFloatStateOf(0f) }
    var playing by remember { mutableStateOf(false) }
    var controlsVisible by remember { mutableStateOf(true) }
    var seeking by remember { mutableStateOf(false) }
    var volume by remember { mutableIntStateOf(PlaybackSession.volume) }
    var muted by remember { mutableStateOf(PlaybackSession.muted) }
    // Volume the user had before dragging the slider (or pressing Down) to 0,
    // so the mute button can restore it instead of leaving playback silent.
    var volumeBeforeMute by remember { mutableIntStateOf(volume.takeIf { it > 0 } ?: 80) }
    var lastSaved by remember { mutableLongStateOf(0L) }
    // One menu at a time, tracked by id in the parent: independent per-menu
    // booleans raced on close/open ordering and could leave menuOpen=false
    // while a menu was still up (controls auto-hid underneath it).
    var openMenu by remember { mutableStateOf<String?>(null) }
    val menuOpen = openMenu != null
    var lastActivityAt by remember { mutableLongStateOf(System.currentTimeMillis()) }
    var isFullscreen by remember {
        mutableStateOf(windowState?.placement == WindowPlacement.Fullscreen)
    }

    fun revealControls() {
        lastActivityAt = System.currentTimeMillis()
        controlsVisible = true
    }

    fun toggleFullscreen() {
        val state = windowState ?: return
        if (state.placement == WindowPlacement.Fullscreen) {
            state.placement = WindowPlacement.Maximized
            isFullscreen = false
        } else {
            state.placement = WindowPlacement.Fullscreen
            isFullscreen = true
        }
        revealControls()
    }

    val resume = remember(request.itemId, currentSeason, currentEpisode) {
        WatchStateStore.resumeFor(request.itemId, currentSeason, currentEpisode)
    }
    var resumeApplied by remember { mutableStateOf(false) }
    var resumeShownUntil by remember { mutableLongStateOf(0L) }
    // Position to restore after a quality/server switch (set by playUrl,
    // consumed once the new rendition reports a length). -1 = fresh start.
    var pendingSeekMs by remember { mutableLongStateOf(-1L) }
    // Bumped by the error overlay's Retry to re-run stream resolution.
    var errorAttempt by remember { mutableIntStateOf(0) }

    val playUrl: (String, ResolvedStream) -> Unit = playUrl@{ url, stream ->
        // Quality/server switches keep the live position; only a fresh start
        // (no meaningful position yet) falls through to the resume checkpoint.
        val keepMs = if (lengthMs > 0L && positionMs > 3_000L) positionMs else -1L
        val quality = stream.qualities.firstOrNull { it.url == url }
            ?.label?.takeIf { it.isNotBlank() } ?: "Auto"
        val started = runCatching {
            PlaybackSession.play(
                request = request,
                url = url,
                referer = stream.referer,
                userAgent = stream.userAgent,
                origin = stream.origin,
                server = stream.server,
                quality = quality,
                streamList = streams,
                selected = selectedIndex,
                local = false,
            )
        }
        if (started.isFailure) {
            error = "Playback engine could not start: " +
                (started.exceptionOrNull()?.message ?: "unknown libmpv error")
            loading = false
            return@playUrl
        }
        positionMs = 0L
        lengthMs = 0L
        sliderFrac = 0f
        resumeApplied = false
        pendingSeekMs = keepMs
        selectedAudioLabel = null
    }

    /**
     * Attaches the subtitle for [stream]: the user's choice for this server if
     * they made one, otherwise the auto pick (default flag → audio language →
     * English → first track). Runs after each (re)load so switching servers
     * keeps the language, like a TV does.
     */
    fun applySubtitlesFor(stream: ResolvedStream) {
        val override = subtitleOverrides[stream.server]
        val target = if (subtitleOverrides.containsKey(stream.server)) override else {
            val audioLang = stream.audioTracks.firstOrNull { it.isDefault }?.language
                ?: stream.audioTracks.firstOrNull()?.language.orEmpty()
            pickDefaultSubtitle(stream.subtitles, audioLang)
        }
        activeSubtitleUrl = target?.url
        if (target == null) {
            controller.disableSubtitles()
            return
        }
        scope.launch {
            val file = downloadSubtitle(target.url)
            if (file != null && streams.getOrNull(selectedIndex)?.url == stream.url) {
                PlaybackSession.trackSubtitle(file)
                controller.setSubtitleFile(file)
            }
        }
    }

    /** Settings → Default quality: pick nearest matching rendition (or best). */
    fun preferredQualityUrl(stream: ResolvedStream): String {
        // Masters pinned for a separate audio rendition must play the master:
        // their variant URLs don't carry the audio groups.
        if (stream.separateAudio) return stream.url
        val qualities = stream.qualityMatch()
        val target = AppPrefs.defaultQualityHeight()
        if (target <= 0 || qualities.isEmpty()) return qualities.firstOrNull()?.url ?: stream.url
        val exact = qualities.firstOrNull { it.height == target }
        if (exact != null) return exact.url
        return qualities.minByOrNull { kotlin.math.abs(it.height - target) }?.url
            ?: qualities.firstOrNull()?.url
            ?: stream.url
    }

    val playStream: (Int) -> Unit = { index ->
        if (index in streams.indices) {
            selectedIndex = index
            val stream = streams[index]
            playUrl(preferredQualityUrl(stream), stream)
            applySubtitlesFor(stream)
        }
    }

    val selectQuality: (com.maxstream.app.stream.ResolvedQuality) -> Unit = { q ->
        streams.getOrNull(selectedIndex)?.let { stream ->
            playUrl(if (stream.separateAudio) stream.url else q.url, stream)
        }
    }

    /**
     * Merges a freshly-resolved server list while keeping the currently
     * playing entry selected/playing (the racing pass may have picked a URL
     * the later pass re-validated differently).
     */
    fun applyServerList(list: List<ResolvedStream>, failed: List<FailedServer>) {
        val current = streams.getOrNull(selectedIndex)
        var merged = list
        if (current != null && list.none { it.url == current.url }) {
            merged = listOf(current) + list.filterNot { it.server.equals(current.server, ignoreCase = true) }
        }
        streams = merged
        failedServers = failed.filter { f -> merged.none { it.server.equals(f.name, ignoreCase = true) } }
        if (current != null) {
            val idx = merged.indexOfFirst { it.url == current.url }
            if (idx >= 0) selectedIndex = idx
        } else if (selectedIndex < 0 && merged.isNotEmpty()) {
            selectedIndex = 0
        }
        PlaybackSession.updateStreams(merged, selectedIndex)
        // The fast passes finish after playback started; if the playing server
        // only got its subtitle list from this pass, attach it now.
        if (current != null && selectedIndex == merged.indexOfFirst { it.url == current.url }) {
            val playingStream = merged.getOrNull(selectedIndex)
            val hasTracks = playingStream?.subtitles?.isNotEmpty() == true
            if (hasTracks && activeSubtitleUrl == null) applySubtitlesFor(playingStream)
        }
    }

    /** Picks an mpv audio track matching the chosen HLS rendition. */
    fun selectAudioTrack(track: ResolvedAudioTrack) {
        val wanted = track.language.lowercase()
        val labelWanted = track.label.lowercase()
        val match = controller.audioTrackDescriptions().firstOrNull { (id, desc) ->
            if (id <= 0) return@firstOrNull false
            val d = desc.lowercase()
            (wanted.isNotBlank() && wanted != "und" && d.contains(wanted)) ||
                (labelWanted.isNotBlank() && d.contains(labelWanted))
        }
        if (match != null) controller.selectAudioTrack(match.first)
        selectedAudioLabel = track.display()
        revealControls()
    }

    /** Re-fetches a server row that failed discovery (picker retry). */
    fun retryServer(name: String) {
        scope.launch {
            val map = withContext(Dispatchers.IO) {
                StreamResolver.resolveServer(
                    name,
                    request.itemId,
                    request.mediaType == "movie",
                    request.season,
                    request.episode,
                    request.title,
                )
            }
            val parsed = parseStreams(listOfNotNull(map))
            if (parsed.isNotEmpty()) {
                applyServerList(
                    streams + parsed,
                    failedServers.filterNot { it.name.equals(name, ignoreCase = true) },
                )
                val idx = streams.indexOfFirst { it.server.equals(name, ignoreCase = true) }
                if (idx >= 0) playStream(idx)
                else applySubtitlesFor(parsed.first())
            }
        }
    }

    fun seekBy(deltaMs: Long) {
        if (lengthMs <= 0L) return
        val next = (positionMs + deltaMs).coerceIn(0L, lengthMs)
        controller.setTime(next)
        positionMs = next
        sliderFrac = next.toFloat() / lengthMs
        revealControls()
    }

    /** Single write path: UI state, session defaults and mpv stay in step. */
    fun setVolume(level: Int) {
        val next = level.coerceIn(0, 100)
        if (next > 0) volumeBeforeMute = next
        volume = next
        // Dragging to 0 mutes; nudging back up or un-muting restores sound.
        muted = next == 0
        PlaybackSession.volume = next
        PlaybackSession.muted = muted
        controller.setVolume(next)
        controller.setMute(muted)
        revealControls()
    }

    fun adjustVolume(delta: Int) {
        // Raising or lowering the volume by keyboard means "I want to hear it".
        if (delta > 0 && muted) {
            setVolume(volume.coerceAtLeast(volumeBeforeMute) + delta)
        } else {
            setVolume(volume + delta)
        }
    }

    fun toggleMute() {
        if (muted || volume == 0) {
            // Unmute: restore the last audible level, never stay at 0 (the old
            // toggle left volume at 0 so "unmute" did nothing audible).
            val restore = volumeBeforeMute.coerceIn(1, 100)
            volume = restore
            muted = false
            PlaybackSession.volume = restore
            PlaybackSession.muted = false
            controller.setVolume(restore)
            controller.setMute(false)
        } else {
            volumeBeforeMute = volume
            muted = true
            PlaybackSession.muted = true
            controller.setMute(true)
        }
        revealControls()
    }

    /** Re-syncs volume/mute from the session when returning from the mini-player. */
    fun syncVolumeFromSession() {
        volume = PlaybackSession.volume
        muted = PlaybackSession.muted
        if (volume > 0) volumeBeforeMute = volume
    }

    fun togglePlayPause() {
        controller.togglePlayPause()
        revealControls()
    }

    fun playEpisode(season: Int, episode: Int) {
        if (isMovie) return
        currentSeason = season
        currentEpisode = episode
        menuSeason = season
        episodePanelOpen = false
    }

    suspend fun playNextEpisode() {
        if (isMovie || autoAdvancing) return
        autoAdvancing = true
        try {
            val numbers = seasonEpisodes.map { it.number }.filter { it > 0 }
            val maxInSeason = numbers.maxOrNull()
            val nextSeason: Int
            val nextEpisode: Int
            if (maxInSeason != null && currentEpisode >= maxInSeason) {
                nextSeason = currentSeason + 1
                nextEpisode = 1
            } else {
                nextSeason = currentSeason
                nextEpisode = currentEpisode + 1
            }
            val nextSeasonEpisodes: List<com.maxstream.app.data.model.Episode> =
                if (nextSeason == currentSeason) {
                    seasonEpisodes
                } else {
                    val cached = menuEpisodesCache[nextSeason]
                    if (cached != null) cached else {
                        val fetched = runCatching { repository.episodes(request.itemId, nextSeason) }.getOrDefault(emptyList())
                        if (fetched.isNotEmpty()) {
                            menuEpisodesCache = menuEpisodesCache + (nextSeason to fetched)
                        }
                        fetched
                    }
                }
            val next = nextSeasonEpisodes.firstOrNull { it.number == nextEpisode }
            if (next == null) return
            if (!next.isReleased()) return
            currentSeason = nextSeason
            currentEpisode = nextEpisode
        } finally {
            autoAdvancing = false
        }
    }

    LaunchedEffect(request.itemId, currentSeason, currentEpisode, request.mediaType, request.localPath, errorAttempt) {
        loading = true
        error = null
        controlsVisible = true
        resumeApplied = false
        pendingSeekMs = -1L
        streams = emptyList()
        failedServers = emptyList()
        selectedIndex = -1
        selectedAudioLabel = null
        resolvingAll = true
        activeSeason = currentSeason
        activeEpisode = currentEpisode
        // Focus now (not just after the first stream lands) so Space/F work
        // while the "Finding streams…" overlay is up.
        runCatching { focusRequester.requestFocus() }

        // Returning from the mini-player: reattach to the live mpv media and
        // source list instead of resolving and starting from zero.
        if (errorAttempt == 0 && PlaybackSession.isActiveFor(request)) {
            streams = PlaybackSession.streams
            selectedIndex = PlaybackSession.selectedIndex
            // Subtitles live inside mpv's new playlist after a server switch;
            // mpv re-selects by language, so just mirror the current track.
            activeSubtitleUrl = if (controller.currentSubtitle() > 0) {
                streams.getOrNull(selectedIndex)?.subtitles?.firstOrNull()?.url
            } else null
            syncVolumeFromSession()
            positionMs = runCatching { controller.time() }.getOrDefault(0L)
            lengthMs = runCatching { controller.length() }.getOrDefault(0L)
            playing = runCatching { controller.isPlaying }.getOrDefault(false)
            if (lengthMs > 0L) sliderFrac = (positionMs.toFloat() / lengthMs).coerceIn(0f, 1f)
            resumeApplied = true
            pendingSeekMs = -1L
            resolvingAll = false
            loading = false
            PlaybackSession.expand()
            return@LaunchedEffect
        }

        // Offline playback bypasses the extractor entirely: the download's
        // local playlist/file is handed straight to mpv.
        request.localPath?.let { path ->
            val started = runCatching {
                PlaybackSession.play(
                    request = request,
                    url = path,
                    referer = null,
                    userAgent = null,
                    origin = null,
                    server = "Download",
                    quality = "Offline",
                    streamList = emptyList(),
                    selected = -1,
                    local = true,
                )
            }
            if (started.isFailure) {
                error = "Could not play the downloaded file: " +
                    (started.exceptionOrNull()?.message ?: "unknown libmpv error")
            }
            streams = emptyList()
            selectedIndex = -1
            failedServers = emptyList()
            resolvingAll = false
            loading = false
            return@LaunchedEffect
        }

        val id = request.itemId
        val isMovie = request.mediaType == "movie"
        val season = currentSeason
        val episode = currentEpisode
        val title = request.title

        coroutineScope {
            // 1) Race: first server to validate wins → playback starts in
            //    seconds instead of waiting for every server.
            val race = async(Dispatchers.IO) {
                runCatching { StreamResolver.resolve(id, isMovie, season, episode, title) }.getOrNull()
            }
            // 2) Fast full list in parallel (short budgets, light validation)
            //    so the server picker paints quickly.
            val fastPass = async(Dispatchers.IO) {
                runCatching {
                    StreamResolver.resolveAll(id, isMovie, season, episode, title, fast = true)
                }.getOrDefault(emptyList())
            }

            val first = race.await()
            val firstParsed = parseStreams(listOfNotNull(first))
            if (firstParsed.isNotEmpty()) {
                streams = firstParsed
                playStream(0)
                loading = false
                runCatching { focusRequester.requestFocus() }
            }

            val fastMaps = fastPass.await()
            if (fastMaps.isNotEmpty()) {
                applyServerList(parseStreams(fastMaps), parseFailedServers(fastMaps))
            }
            if (loading && streams.isNotEmpty()) {
                playStream(0)
                loading = false
                runCatching { focusRequester.requestFocus() }
            }

            // 3) Full validated pass in the background hardens the picker;
            //    the screen stays interactive on whatever the fast passes gave us.
            val fullMaps = runCatching {
                StreamResolver.resolveAll(id, isMovie, season, episode, title, fast = false)
            }.getOrDefault(emptyList())
            if (fullMaps.isNotEmpty()) {
                applyServerList(parseStreams(fullMaps), parseFailedServers(fullMaps))
            }
            resolvingAll = false
            if (loading) {
                loading = false
                if (streams.isEmpty()) {
                    error = "No playable source could be resolved for this title."
                } else {
                    playStream(0)
                    runCatching { focusRequester.requestFocus() }
                }
            }
        }
    }

    // Fetch series seasons for the episodes browser + autoplay.
    LaunchedEffect(request.itemId) {
        if (isMovie) return@LaunchedEffect
        val details = runCatching { repository.details(request.itemId, "tv") }.getOrNull()
        seasons = details?.seasons ?: emptyList()
        if (seasons.isNotEmpty() && currentSeason !in seasons.map { it.seasonNumber }) {
            // keep currentSeason as is if possible
        }
        menuSeason = currentSeason
    }

    LaunchedEffect(currentSeason) {
        if (isMovie) return@LaunchedEffect
        if (!menuEpisodesCache.containsKey(currentSeason)) {
            val eps = runCatching { repository.episodes(request.itemId, currentSeason) }.getOrDefault(emptyList())
            menuEpisodesCache = menuEpisodesCache + (currentSeason to eps)
        }
        seasonEpisodes = menuEpisodesCache[currentSeason] ?: emptyList()
    }

    // Resolve the next episode for the bottom-right preview (mobile-style).
    LaunchedEffect(currentSeason, currentEpisode, seasonEpisodes) {
        if (isMovie) {
            showNextPreview = false
            nextPreviewSeason = 0
            return@LaunchedEffect
        }
        val numbers = seasonEpisodes.map { it.number }.filter { it > 0 }
        val maxInSeason = numbers.maxOrNull()
        val (ns, ne) = if (maxInSeason != null && currentEpisode >= maxInSeason) {
            (currentSeason + 1) to 1
        } else {
            currentSeason to (currentEpisode + 1)
        }
        val eps = if (ns == currentSeason) {
            seasonEpisodes
        } else {
            val cached = menuEpisodesCache[ns]
            if (cached != null) cached else {
                val fetched = runCatching { repository.episodes(request.itemId, ns) }.getOrDefault(emptyList())
                if (fetched.isNotEmpty()) {
                    menuEpisodesCache = menuEpisodesCache + (ns to fetched)
                }
                fetched
            }
        }
        val next = eps.firstOrNull { it.number == ne }
        if (next == null || !next.isReleased()) {
            showNextPreview = false
            nextPreviewSeason = 0
            return@LaunchedEffect
        }
        nextPreviewSeason = ns
        nextPreviewEpisode = ne
        nextPreviewName = next.title
        nextPreviewStill = com.maxstream.app.core.AppConfig.imageUrl("w500", next.stillPath)
    }

    LaunchedEffect(Unit) {
        while (true) {
            if (positionMs <= 0L) positionMs = controller.time()
            lengthMs = controller.length()
            playing = controller.isPlaying
            if (!seeking) {
                val p = controller.time()
                if (p > 0L) positionMs = p
                if (lengthMs > 0L) sliderFrac = (positionMs.toFloat() / lengthMs).coerceIn(0f, 1f)
            }
            // Next-episode preview (mobile-style) + autoplay on finish for series.
            if (!isMovie && lengthMs > 0L) {
                val remaining = (lengthMs - positionMs).coerceAtLeast(0L)
                val countdown = (remaining / 1000L).toInt().coerceIn(0, 30)
                val shouldShow = remaining <= 30_000L && nextPreviewSeason != 0
                if (shouldShow != showNextPreview || (shouldShow && countdown != nextPreviewCountdown)) {
                    showNextPreview = shouldShow
                    nextPreviewCountdown = countdown
                }
                val ended = controller.eofReached()
                if (ended && !autoAdvancing && !endedHandled && nextPreviewSeason != 0) {
                    endedHandled = true
                    scope.launch { playNextEpisode() }
                }
                if (!ended) endedHandled = false
            } else if (showNextPreview) {
                showNextPreview = false
            }
            // Switch-position restore first; otherwise apply the saved
            // checkpoint on a genuinely fresh start.
            if (pendingSeekMs >= 0L && lengthMs > 0L) {
                val target = pendingSeekMs.coerceAtMost((lengthMs - 5_000L).coerceAtLeast(0L))
                controller.setTime(target)
                positionMs = target
                if (lengthMs > 0L) sliderFrac = (target.toFloat() / lengthMs).coerceIn(0f, 1f)
                pendingSeekMs = -1L
                resumeApplied = true
            } else if (!resumeApplied && resume != null && resume.positionMs > 30_000L && lengthMs > 0L) {
                controller.setTime(resume.positionMs.coerceAtMost((lengthMs - 5_000L).coerceAtLeast(0L)))
                resumeApplied = true
                resumeShownUntil = System.currentTimeMillis() + 3_000L
            }
            if (playing && lengthMs > 0L && positionMs - lastSaved >= 10_000L) {
                lastSaved = positionMs
                // Disk/network off the UI thread; capture values for the IO job.
                val pos = positionMs
                val len = lengthMs
                launch(Dispatchers.IO) {
                    runCatching {
                        repository.saveProgress(itemFrom(request), activeSeason, activeEpisode, pos, len)
                    }.onFailure { e -> println("PlayerScreen: progress save failed: $e") }
                }
            }
            delay(600)
        }
    }

    // Auto-hide only while playing and no menu/seek is open (~1s).
    LaunchedEffect(controlsVisible, playing, loading, menuOpen, seeking) {
        if (!controlsVisible || loading || menuOpen || seeking) return@LaunchedEffect
        while (controlsVisible && !loading && !menuOpen && !seeking) {
            delay(150)
            if (!playing) {
                // Paused → keep controls up (browser/mpv pattern).
                lastActivityAt = System.currentTimeMillis()
                continue
            }
            if (System.currentTimeMillis() - lastActivityAt >= 1000L) {
                controlsVisible = false
            }
        }
    }

    DisposableEffect(Unit) {
        onDispose {
            if (lengthMs > 0L) {
                // teardownScope (not `scope`): rememberCoroutineScope is already
                // cancelled when onDispose runs, so the final save never landed.
                teardownScope.launch {
                    runCatching {
                        repository.saveProgress(itemFrom(request), activeSeason, activeEpisode, positionMs, lengthMs)
                    }.onFailure { e -> println("PlayerScreen: final progress save failed: $e") }
                }
            }
            // Keep mpv alive: Shell shows the mini-player while this screen is
            // unmounted. Session disposal (sign-out/close) calls release().
            PlaybackSession.onScreenDetached()
        }
    }

    Box(
        Modifier
            .fillMaxSize()
            .focusRequester(focusRequester)
            .focusable()
            .onKeyEvent { event ->
                if (event.type != KeyEventType.KeyDown) return@onKeyEvent false
                when (event.key) {
                    Key.Spacebar, Key.Backspace -> {
                        togglePlayPause()
                        true
                    }
                    Key.F -> {
                        toggleFullscreen()
                        true
                    }
                    Key.Escape -> {
                        val state = windowState
                        when {
                            state?.placement == WindowPlacement.Fullscreen -> {
                                state.placement = WindowPlacement.Maximized
                                isFullscreen = false
                                revealControls()
                                true
                            }
                            else -> {
                                onBack()
                                true
                            }
                        }
                    }
                    Key.M -> {
                        toggleMute()
                        true
                    }
                    Key.I -> {
                        revealControls()
                        true
                    }
                    Key.DirectionLeft -> {
                        if (event.isCtrlPressed) seekBy(-60_000L) else seekBy(-10_000L)
                        true
                    }
                    Key.DirectionRight -> {
                        if (event.isCtrlPressed) seekBy(60_000L) else seekBy(10_000L)
                        true
                    }
                    Key.VolumeUp -> {
                        adjustVolume(+10)
                        true
                    }
                    Key.VolumeDown -> {
                        adjustVolume(-10)
                        true
                    }
                    Key.DirectionUp -> {
                        adjustVolume(+10)
                        true
                    }
                    Key.DirectionDown -> {
                        adjustVolume(-10)
                        true
                    }
                    else -> false
                }
            },
    ) {
        // The video is an ordinary Compose layer; controls and overlays paint
        // over it without any platform interop complexity.
        PlayerSurface(Modifier.fillMaxSize())

        // Pointer layer: reveal on move; click toggles controls (not play).
        Box(
            Modifier
                .fillMaxSize()
                .onPointerEvent(PointerEventType.Move) { revealControls() }
                .onPointerEvent(PointerEventType.Enter) { revealControls() }
                .onPointerEvent(PointerEventType.Press) {
                    runCatching { focusRequester.requestFocus() }
                    revealControls()
                }
                .clickable(
                    indication = null,
                    interactionSource = remember { MutableInteractionSource() },
                ) { controlsVisible = !controlsVisible },
        )

        // ── Top chrome ───────────────────────────────────────────────────────
        AnimatedVisibility(visible = controlsVisible) {
            Surface(color = Color.Transparent, modifier = Modifier.fillMaxWidth()) {
                Box(
                    Modifier
                        .fillMaxWidth()
                        .background(Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.75f), Color.Transparent)))
                        .onPointerEvent(PointerEventType.Move) { revealControls() }
                        .onPointerEvent(PointerEventType.Enter) { revealControls() },
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
                    ) {
                        IconButton(
                            onClick = onBack,
                            modifier = Modifier.appFocusRing(ringColor = Color.White),
                        ) {
                            Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = Color.White)
                        }
                        Column(Modifier.weight(1f).padding(start = 6.dp)) {
                            Text(
                                request.title,
                                color = Color.White,
                                fontWeight = FontWeight.SemiBold,
                                fontSize = 16.sp,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                            if (request.mediaType == "tv") {
                                Text(
                                    "Season $currentSeason • Episode $currentEpisode",
                                    color = Color.White.copy(alpha = 0.8f),
                                    fontSize = 13.sp,
                                )
                            }
                        }
                        if (isSeries) {
                            IconButton(
                                onClick = {
                                    episodePanelOpen = !episodePanelOpen
                                    menuSeason = currentSeason
                                    if (!menuEpisodesCache.containsKey(menuSeason)) {
                                        scope.launch {
                                            episodeMenuLoading = true
                                            val eps = runCatching { repository.episodes(request.itemId, menuSeason) }.getOrDefault(emptyList())
                                            menuEpisodesCache = menuEpisodesCache + (menuSeason to eps)
                                            episodeMenuLoading = false
                                        }
                                    }
                                    revealControls()
                                },
                                modifier = Modifier.appFocusRing(ringColor = Color.White),
                            ) {
                                Icon(Icons.Default.Tv, contentDescription = "Episodes", tint = Color.White)
                            }
                        }
                        IconButton(
                            onClick = { toggleFullscreen() },
                            modifier = Modifier.appFocusRing(ringColor = Color.White),
                        ) {
                            Icon(
                                if (isFullscreen || windowState?.placement == WindowPlacement.Fullscreen)
                                    Icons.Default.FullscreenExit
                                else Icons.Default.Fullscreen,
                                contentDescription = "Fullscreen",
                                tint = Color.White,
                            )
                        }
                    }
                }
            }
        }

        // ── Bottom chrome: seek + transport + menus ─────────────────────────
        AnimatedVisibility(visible = controlsVisible, modifier = Modifier.align(Alignment.BottomCenter)) {
            Column(
                Modifier
                    .fillMaxWidth()
                    .background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.85f))))
                    .onPointerEvent(PointerEventType.Move) { revealControls() }
                    .onPointerEvent(PointerEventType.Enter) { revealControls() }
                    .padding(horizontal = 18.dp, vertical = 12.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    IconButton(
                        onClick = { togglePlayPause() },
                        modifier = Modifier.appFocusRing(ringColor = Color.White),
                    ) {
                        Icon(
                            if (playing) Icons.Default.Pause else Icons.Default.PlayArrow,
                            "Play/Pause",
                            tint = Color.White,
                            modifier = Modifier.width(26.dp).height(26.dp),
                        )
                    }
                    Text(fmtPlayer(positionMs), color = Color.White, fontSize = 12.sp)

                    Slider(
                        value = sliderFrac,
                        onValueChange = { seeking = true; sliderFrac = it; revealControls() },
                        onValueChangeFinished = {
                            controller.setPosition(sliderFrac)
                            positionMs = (sliderFrac * lengthMs).toLong()
                            seeking = false
                            revealControls()
                        },
                        modifier = Modifier.weight(1f).padding(horizontal = 12.dp),
                    )

                    Text(fmtPlayer(lengthMs), color = Color.White, fontSize = 12.sp)

                    IconButton(
                        onClick = { toggleMute() },
                        modifier = Modifier.appFocusRing(ringColor = Color.White),
                    ) {
                        Icon(
                            when {
                                muted || volume == 0 -> Icons.AutoMirrored.Filled.VolumeOff
                                volume < 50 -> Icons.AutoMirrored.Filled.VolumeDown
                                else -> Icons.AutoMirrored.Filled.VolumeUp
                            },
                            if (muted || volume == 0) "Unmute" else "Mute",
                            tint = Color.White,
                        )
                    }
                    Slider(
                        // The thumb mirrors the real player volume, including
                        // keyboard changes; dragging it always un-mutes.
                        value = volume.toFloat(),
                        onValueChange = { setVolume(it.toInt()) },
                        modifier = Modifier.width(100.dp),
                    )
                    Text(
                        if (muted || volume == 0) "Muted" else "$volume%",
                        color = Color.White.copy(alpha = 0.75f),
                        fontSize = 11.sp,
                        modifier = Modifier.width(40.dp),
                    )
                    IconButton(
                        onClick = { toggleFullscreen() },
                        modifier = Modifier.appFocusRing(ringColor = Color.White),
                    ) {
                        Icon(
                            if (windowState?.placement == WindowPlacement.Fullscreen)
                                Icons.Default.FullscreenExit
                            else Icons.Default.Fullscreen,
                            contentDescription = "Fullscreen",
                            tint = Color.White,
                        )
                    }
                }

                Row(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier.padding(top = 4.dp),
                ) {
                    val currentStream = streams.getOrNull(selectedIndex)
                    val qualities = currentStream?.qualityMatch().orEmpty()
                    val subs = currentStream?.subtitles.orEmpty()
                    // Single shared open-menu id: opening another closes the
                    // current one, and dismissal state can't race across menus.
                    val setMenu: (String, Boolean) -> Unit = { id, value ->
                        openMenu = when {
                            value -> id
                            openMenu == id -> null
                            else -> openMenu
                        }
                    }

                    PlayerMenu(
                        icon = Icons.Default.Dns,
                        label = when {
                            offline -> "Offline"
                            streams.size > 1 -> "Server (${selectedIndex + 1}/${streams.size})"
                            else -> "Server"
                        },
                        enabled = !offline && (streams.isNotEmpty() || failedServers.isNotEmpty()),
                        open = openMenu == "server",
                        onOpenChange = { setMenu("server", it) },
                        onInteract = { revealControls() },
                    ) { dismiss ->
                        if (streams.isEmpty() && resolvingAll) {
                            DropdownMenuItem(
                                text = { Text("Resolving…", color = Color.White.copy(alpha = 0.6f)) },
                                onClick = {},
                            )
                        }
                        streams.forEachIndexed { index, stream ->
                            DropdownMenuItem(
                                text = {
                                    Text(
                                        buildString {
                                            append(stream.server)
                                            if (index == selectedIndex) append("  ✓")
                                        },
                                        color = Color.White,
                                    )
                                },
                                onClick = {
                                    dismiss()
                                    playStream(index)
                                    applySubtitlesFor(stream)
                                },
                            )
                        }
                        if (resolvingAll && streams.isNotEmpty()) {
                            DropdownMenuItem(
                                text = { Text("Checking more servers…", color = Color.White.copy(alpha = 0.55f)) },
                                onClick = {},
                            )
                        }
                        failedServers.forEach { f ->
                            DropdownMenuItem(
                                text = { Text("${f.name} — unavailable (retry)", color = Color(0xFFFFB74D)) },
                                onClick = {
                                    dismiss()
                                    retryServer(f.name)
                                },
                            )
                        }
                    }

                    PlayerMenu(
                        icon = Icons.Default.HighQuality,
                        label = when {
                            offline -> "Downloaded"
                            currentStream?.separateAudio == true -> "Quality (adaptive)"
                            qualities.size > 1 -> "Quality (${qualities.size})"
                            else -> "Quality"
                        },
                        enabled = !offline && qualities.isNotEmpty() && currentStream?.separateAudio != true,
                        open = openMenu == "quality",
                        onOpenChange = { setMenu("quality", it) },
                        onInteract = { revealControls() },
                    ) { dismiss ->
                        if (qualities.isEmpty()) {
                            DropdownMenuItem(
                                text = { Text("Default stream", color = Color.White.copy(alpha = 0.6f)) },
                                onClick = {},
                            )
                        }
                        qualities.forEach { q ->
                            DropdownMenuItem(
                                text = { Text(q.label.ifBlank { "${q.height}p" }, color = Color.White) },
                                onClick = {
                                    dismiss()
                                    selectQuality(q)
                                },
                            )
                        }
                    }

                    val audioTracks = currentStream?.audioTracks.orEmpty()
                    PlayerMenu(
                        icon = Icons.Default.Audiotrack,
                        label = when {
                            selectedAudioLabel != null -> "Audio ($selectedAudioLabel)"
                            audioTracks.size > 1 -> "Audio (${audioTracks.size})"
                            else -> "Audio"
                        },
                        enabled = audioTracks.isNotEmpty(),
                        open = openMenu == "audio",
                        onOpenChange = { setMenu("audio", it) },
                        onInteract = { revealControls() },
                    ) { dismiss ->
                        DropdownMenuItem(
                            text = { Text("Default (auto)", color = Color.White) },
                            onClick = {
                                dismiss()
                                selectedAudioLabel = null
                                controller.selectAudioTrack(-1)
                                revealControls()
                            },
                        )
                        audioTracks.forEach { track ->
                            DropdownMenuItem(
                                text = { Text(track.display(), color = Color.White) },
                                onClick = {
                                    dismiss()
                                    selectAudioTrack(track)
                                },
                            )
                        }
                    }

                    val autoSub = currentStream?.let { stream ->
                        val audioLang = stream.audioTracks.firstOrNull { it.isDefault }?.language
                            ?: stream.audioTracks.firstOrNull()?.language.orEmpty()
                        pickDefaultSubtitle(stream.subtitles, audioLang)
                    }
                    PlayerMenu(
                        icon = Icons.Default.ClosedCaption,
                        label = when {
                            activeSubtitleUrl == null -> "Subtitles off"
                            subs.size > 1 -> "Subtitles (${subs.size})"
                            else -> "Subtitles"
                        },
                        enabled = true,
                        open = openMenu == "subs",
                        onOpenChange = { setMenu("subs", it) },
                        onInteract = { revealControls() },
                    ) { dismiss ->
                        DropdownMenuItem(
                            text = {
                                Text(
                                    if (activeSubtitleUrl == null) "Off  ✓" else "Off",
                                    color = Color.White,
                                )
                            },
                            onClick = {
                                dismiss()
                                currentStream?.let { subtitleOverrides = subtitleOverrides + (it.server to null) }
                                activeSubtitleUrl = null
                                controller.disableSubtitles()
                            },
                        )
                        subs.forEach { sub ->
                            val active = activeSubtitleUrl == sub.url
                            DropdownMenuItem(
                                text = { Text(sub.display() + if (active) "  ✓" else "", color = Color.White) },
                                onClick = {
                                    dismiss()
                                    activeSubtitleUrl = sub.url
                                    currentStream?.let { subtitleOverrides = subtitleOverrides + (it.server to sub) }
                                    scope.launch {
                                        val f = downloadSubtitle(sub.url)
                                        if (f != null) {
                                            PlaybackSession.trackSubtitle(f)
                                            controller.setSubtitleFile(f)
                                        }
                                    }
                                },
                            )
                        }
                        if (subs.isEmpty()) {
                            DropdownMenuItem(
                                text = { Text("No tracks for this source", color = Color.White.copy(alpha = 0.55f)) },
                                onClick = {},
                            )
                        } else if (!subtitleOverrides.containsKey(currentStream?.server)) {
                            DropdownMenuItem(
                                text = {
                                    Text(
                                        "Auto: ${autoSub?.display() ?: "first track"} (matches audio)",
                                        color = Color.White.copy(alpha = 0.55f),
                                        fontSize = 12.sp,
                                    )
                                },
                                onClick = {},
                            )
                        }
                    }

                    Spacer(Modifier.weight(1f))
                    Text(
                        "Space / Backspace play-pause  •  ←/→ ±10s  •  ↑/↓ volume  •  M mute  •  F fullscreen",
                        color = Color.White.copy(alpha = 0.45f),
                        fontSize = 11.sp,
                        modifier = Modifier.align(Alignment.CenterVertically).padding(start = 8.dp),
                    )
                }
            }
        }

        // ── Resume chip ─────────────────────────────────────────────────────
        if (resumeApplied && System.currentTimeMillis() < resumeShownUntil) {
            Surface(
                color = Color.Black.copy(alpha = 0.6f),
                shape = RoundedCornerShape(8.dp),
                modifier = Modifier.align(Alignment.TopStart).padding(top = 64.dp, start = 24.dp),
            ) {
                Text(
                    "Resumed from ${fmtPlayer(resume?.positionMs ?: 0L)}",
                    color = Color.White,
                    fontSize = 13.sp,
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                )
            }
        }

        // ── Loading / error overlays ───────────────────────────────────────
        if (loading) {
            Box(
                Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.55f)),
                contentAlignment = Alignment.Center,
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    CircularProgressIndicator(color = Color.White, strokeWidth = 3.dp)
                    Spacer(Modifier.height(16.dp))
                    Text(
                        "Finding streams…",
                        color = Color.White,
                        fontSize = 15.sp,
                        fontWeight = FontWeight.Medium,
                    )
                    Spacer(Modifier.height(6.dp))
                    Text(
                        request.title,
                        color = Color.White.copy(alpha = 0.7f),
                        fontSize = 13.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
        if (error != null) {
            Surface(
                color = Color.Black.copy(alpha = 0.85f),
                modifier = Modifier.fillMaxSize(),
            ) {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier.align(Alignment.Center),
                ) {
                    Text(error.orEmpty(), color = Color.White, fontSize = 15.sp)
                    Spacer(Modifier.height(20.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Button(
                            onClick = {
                                // Re-run the resolution effect (errorAttempt is a key).
                                error = null
                                errorAttempt++
                            },
                            modifier = Modifier.appFocusRing(cornerRadius = 8.dp),
                        ) {
                            Icon(Icons.Default.Refresh, null, modifier = Modifier.width(16.dp).height(16.dp))
                            Spacer(Modifier.width(6.dp))
                            Text("Retry")
                        }
                        TextButton(
                            onClick = onBack,
                            modifier = Modifier.appFocusRing(cornerRadius = 8.dp),
                        ) {
                            Text("Go back", color = Color.White.copy(alpha = 0.85f))
                        }
                    }
                }
            }
        }
        // Next-episode preview (bottom-right, mobile-style).
        if (showNextPreview && nextPreviewSeason != 0) {
            Surface(
                color = Color(0xFF202124),
                shape = RoundedCornerShape(10.dp),
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(20.dp),
            ) {
                Row(
                    modifier = Modifier
                        .width(340.dp)
                        .padding(10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(
                        modifier = Modifier
                            .width(110.dp)
                            .height(66.dp)
                            .clip(RoundedCornerShape(6.dp))
                            .background(Color.Black),
                        contentAlignment = Alignment.Center,
                    ) {
                        val url = nextPreviewStill
                        if (url != null) {
                            AsyncImage(
                                model = url,
                                contentDescription = null,
                                contentScale = ContentScale.Crop,
                                modifier = Modifier.fillMaxSize(),
                            )
                        } else {
                            Icon(Icons.Default.Tv, null, tint = Color.White.copy(alpha = 0.6f))
                        }
                    }
                    Spacer(Modifier.width(10.dp))
                    Column(Modifier.weight(1f)) {
                        Text(
                            "Next episode in $nextPreviewCountdown seconds",
                            color = Color.White.copy(alpha = 0.7f),
                            fontSize = 12.sp,
                        )
                        Spacer(Modifier.height(3.dp))
                        Text(
                            "S${nextPreviewSeason}E${nextPreviewEpisode} · $nextPreviewName",
                            color = Color.White,
                            fontWeight = FontWeight.Bold,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                        )
                        Row {
                            TextButton(onClick = { scope.launch { playNextEpisode() } }) {
                                Text("Play now", color = Color.White)
                            }
                            TextButton(onClick = { showNextPreview = false }) {
                                Text("Cancel", color = Color.White.copy(alpha = 0.7f))
                            }
                        }
                    }
                }
            }
        }

        // Episodes panel (TV-style seasons + episodes).
        if (episodePanelOpen && isSeries) {
            Surface(
                color = Color(0xF2181818),
                shape = RoundedCornerShape(12.dp),
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .padding(top = 76.dp, end = 16.dp)
                    .width(420.dp),
            ) {
                Column {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 20.dp, vertical = 14.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            request.title,
                            color = Color(0xFFE50914),
                            fontSize = 18.sp,
                            fontWeight = FontWeight.Bold,
                            maxLines = 1,
                            modifier = Modifier.weight(1f),
                        )
                        Text("Episodes", color = Color(0xFFE50914), fontSize = 16.sp, fontWeight = FontWeight.Bold)
                    }
                    Box(Modifier.fillMaxWidth().height(1.dp).background(Color(0x40FFFFFF)))
                    if (seasons.isNotEmpty()) {
                        val seasonListState = rememberLazyListState()
                        LaunchedEffect(menuSeason) {
                            val idx = seasons.indexOfFirst { it.seasonNumber == menuSeason }
                            if (idx >= 0) seasonListState.animateScrollToItem(idx)
                        }
                        LazyRow(
                            state = seasonListState,
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 12.dp, vertical = 10.dp),
                            horizontalArrangement = Arrangement.spacedBy(10.dp),
                        ) {
                            items(seasons.size) { sIdx ->
                                val season = seasons[sIdx]
                                val active = season.seasonNumber == menuSeason
                                Box(
                                    modifier = Modifier
                                        .background(
                                            if (active) Color(0xFFE50914) else Color.Transparent,
                                            RoundedCornerShape(20.dp),
                                        )
                                        .border(
                                            1.dp,
                                            if (active) Color.Transparent else Color(0x40FFFFFF),
                                            RoundedCornerShape(20.dp),
                                        )
                                        .clickable {
                                            menuSeason = season.seasonNumber
                                            if (!menuEpisodesCache.containsKey(menuSeason)) {
                                                scope.launch {
                                                    episodeMenuLoading = true
                                                    val eps = runCatching { repository.episodes(request.itemId, menuSeason) }.getOrDefault(emptyList())
                                                    menuEpisodesCache = menuEpisodesCache + (menuSeason to eps)
                                                    episodeMenuLoading = false
                                                }
                                            }
                                        }
                                        .padding(horizontal = 18.dp, vertical = 8.dp),
                                ) {
                                    Text(
                                        if (season.name.isNotEmpty() && season.name.length <= 14) season.name else "Season ${season.seasonNumber}",
                                        color = if (active) Color.White else Color(0xB3FFFFFF),
                                        fontSize = 16.sp,
                                        fontWeight = if (active) FontWeight.Bold else FontWeight.Normal,
                                    )
                                }
                            }
                        }
                        Box(Modifier.fillMaxWidth().height(1.dp).background(Color(0x40FFFFFF)))
                    }
                    val episodes = menuEpisodesCache[menuSeason] ?: emptyList()
                    when {
                        episodeMenuLoading && episodes.isEmpty() -> {
                            Box(Modifier.fillMaxWidth().height(120.dp), contentAlignment = Alignment.Center) {
                                CircularProgressIndicator(color = Color(0xFFE50914))
                            }
                        }
                        episodes.isEmpty() -> {
                            Box(Modifier.fillMaxWidth().height(120.dp), contentAlignment = Alignment.Center) {
                                Text("No episodes found", color = Color(0xB3FFFFFF), fontSize = 16.sp)
                            }
                        }
                        else -> {
                            val listState = rememberLazyListState()
                            LaunchedEffect(menuSeason) { /* reset */ }
                            LazyColumn(
                                state = listState,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .heightIn(max = 420.dp)
                                    .padding(vertical = 6.dp),
                            ) {
                                items(episodes.size) { index ->
                                    val ep = episodes[index]
                                    val released = ep.isReleased()
                                    val isPlaying = menuSeason == currentSeason && ep.number == currentEpisode
                                    Row(
                                        modifier = Modifier
                                            .fillMaxWidth()
                                            .padding(horizontal = 14.dp, vertical = 6.dp)
                                            .background(
                                                if (isPlaying) Color(0x33E50914) else Color.Transparent,
                                                RoundedCornerShape(8.dp),
                                            )
                                            .border(
                                                1.dp,
                                                if (isPlaying) Color(0xFFE50914) else Color(0x40FFFFFF),
                                                RoundedCornerShape(8.dp),
                                            )
                                            .clickable(enabled = released) {
                                                playEpisode(menuSeason, ep.number)
                                            }
                                            .padding(8.dp),
                                        verticalAlignment = Alignment.CenterVertically,
                                    ) {
                                        Box(
                                            modifier = Modifier
                                                .width(148.dp)
                                                .height(80.dp)
                                                .clip(RoundedCornerShape(6.dp))
                                                .background(Color(0xFF2A2A2A)),
                                        ) {
                                            val url = AppConfig.imageUrl("w500", ep.stillPath)
                                            if (url != null) {
                                                AsyncImage(
                                                    model = url,
                                                    contentDescription = null,
                                                    modifier = Modifier.fillMaxSize(),
                                                    contentScale = ContentScale.Crop,
                                                )
                                            }
                                        }
                                        Spacer(Modifier.width(14.dp))
                                        Column(Modifier.weight(1f)) {
                                            Text(
                                                "S$menuSeason  E${ep.number}",
                                                color = if (isPlaying) Color(0xFFE50914) else Color(0xB3FFFFFF),
                                                fontSize = 15.sp,
                                                fontWeight = if (isPlaying) FontWeight.Bold else FontWeight.Normal,
                                            )
                                            Spacer(Modifier.height(4.dp))
                                            Text(
                                                ep.title,
                                                color = if (released) Color.White else Color(0x61FFFFFF),
                                                fontSize = 16.sp,
                                                maxLines = 1,
                                            )
                                            if (!released && !ep.airDate.isNullOrBlank()) {
                                                Spacer(Modifier.height(4.dp))
                                                Text(
                                                    "To be released on ${formatReleaseDate(ep.airDate!!)}",
                                                    color = Color(0xFFF5B81B),
                                                    fontSize = 12.sp,
                                                    maxLines = 1,
                                                )
                                            }
                                        }
                                        if (isPlaying) {
                                            Text("▶", color = Color.White, fontSize = 20.sp)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}


@Composable
private fun PlayerMenu(
    icon: ImageVector,
    label: String,
    enabled: Boolean,
    open: Boolean,
    onOpenChange: (Boolean) -> Unit,
    onInteract: () -> Unit = {},
    content: @Composable androidx.compose.foundation.layout.ColumnScope.(dismiss: () -> Unit) -> Unit,
) {
    Box {
        Surface(
            color = Color.White.copy(alpha = 0.10f),
            shape = RoundedCornerShape(6.dp),
            modifier = Modifier
                .clickable(enabled = enabled) {
                    onOpenChange(true)
                    onInteract()
                }
                .appFocusRing(cornerRadius = 6.dp, ringColor = Color.White),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
            ) {
                Icon(icon, null, tint = if (enabled) Color.White else Color.White.copy(alpha = 0.4f), modifier = Modifier.width(16.dp).height(16.dp))
                Spacer(Modifier.width(6.dp))
                Text(
                    label,
                    color = if (enabled) Color.White else Color.White.copy(alpha = 0.4f),
                    fontSize = 13.sp,
                )
            }
        }
        DropdownMenu(
            expanded = open,
            onDismissRequest = { onOpenChange(false) },
            containerColor = Color(0xFF1E1E1E),
        ) {
            // DropdownMenuItem does not dismiss itself; items call dismiss().
            content { onOpenChange(false) }
        }
    }
}

private fun itemFrom(request: PlayRequest) = MediaItem(
    id = request.itemId,
    title = request.title,
    mediaType = request.mediaType,
    overview = "",
)

private fun fmtPlayer(ms: Long): String {
    val totalSec = ms / 1000
    val h = totalSec / 3600
    val m = (totalSec % 3600) / 60
    val s = totalSec % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%02d:%02d".format(m, s)
}

private val subHttp: HttpClient by lazy {
    HttpClient.newBuilder()
        .followRedirects(HttpClient.Redirect.NORMAL)
        .connectTimeout(Duration.ofSeconds(10))
        .build()
}

/** Downloads a subtitle to a temp file (only from URLs this app controls). */
private suspend fun downloadSubtitle(url: String): String? = withContext(Dispatchers.IO) {
    runCatching {
        val req = HttpRequest.newBuilder(URI(url)).GET()
            .timeout(Duration.ofSeconds(20))
            .header("User-Agent", "Mozilla/5.0").build()
        val resp = subHttp.send(req, HttpResponse.BodyHandlers.ofByteArray())
        if (resp.statusCode() !in 200..299) return@runCatching null
        val ext = when (url.substringAfterLast('.', "").substringBefore('?').lowercase()) {
            "srt" -> ".srt"
            "ass", "ssa" -> ".ass"
            else -> ".vtt"
        }
        val tmp: Path = Files.createTempFile("maxstream-sub", ext)
        Files.write(tmp, resp.body())
        tmp.toString()
    }.onFailure { e -> println("PlayerScreen: subtitle download failed: $e") }.getOrNull()
}

private fun com.maxstream.app.data.model.Episode.isReleased(): Boolean {
    val airDate = airDate ?: return true
    if (airDate.isBlank()) return true
    val p = airDate.trim().removeSuffix("T00:00:00").split("-")
    if (p.size < 3) return true
    val y = p[0].toIntOrNull() ?: return true
    val m = p[1].toIntOrNull() ?: return true
    val d = p[2].substring(0, minOf(2, p[2].length)).toIntOrNull() ?: return true
    val now = java.util.Calendar.getInstance()
    val by = now.get(java.util.Calendar.YEAR)
    val bm = now.get(java.util.Calendar.MONTH) + 1
    val bd = now.get(java.util.Calendar.DAY_OF_MONTH)
    if (y != by) return y < by
    if (m != bm) return m < bm
    return d <= bd
}

private fun formatReleaseDate(airDate: String): String {
    if (airDate.isBlank()) return airDate
    val p = airDate.trim().removeSuffix("T00:00:00").split("-")
    if (p.size < 3) return airDate.trim()
    val y = p[0].trim()
    val m = p[1].toIntOrNull()
    val d = p[2].substring(0, minOf(2, p[2].length)).toIntOrNull()
    if (y.isBlank() || m == null || d == null || m !in 1..12) return airDate.trim()
    val months = arrayOf("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
    return "${months[m - 1]} $d, $y"
}
