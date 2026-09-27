package com.maxstream.app.ui.screens

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
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
import androidx.compose.runtime.mutableStateListOf
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
import androidx.compose.ui.awt.SwingPanel
import androidx.compose.ui.window.WindowPlacement
import androidx.compose.ui.window.WindowState
import com.maxstream.app.data.AppPrefs
import com.maxstream.app.data.WatchStateStore
import com.maxstream.app.data.model.MediaItem
import com.maxstream.app.data.model.PlayRequest
import com.maxstream.app.data.repository.MediaRepository
import com.maxstream.app.player.PlayerController
import com.maxstream.app.stream.FailedServer
import com.maxstream.app.stream.ResolvedAudioTrack
import com.maxstream.app.stream.ResolvedStream
import com.maxstream.app.stream.StreamResolver
import com.maxstream.app.stream.parseFailedServers
import com.maxstream.app.stream.parseStreams
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
 * Desktop player with VLC-style overlay controls:
 * - Space / Backspace toggle play-pause (focus stays on Compose, not AWT).
 * - F toggles window fullscreen; Esc leaves fullscreen first, then goes back.
 * - Controls stay visible while paused or while a menu is open; auto-hide
 *   ~1s while playing (VLC fullscreen-controller timeout).
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
    val controller = remember { PlayerController() }
    val scope = rememberCoroutineScope()
    val focusRequester = remember { FocusRequester() }

    var streams by remember { mutableStateOf<List<ResolvedStream>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }
    var selectedIndex by remember { mutableIntStateOf(-1) }
    var failedServers by remember { mutableStateOf<List<FailedServer>>(emptyList()) }
    var resolvingAll by remember { mutableStateOf(false) }
    var selectedAudioLabel by remember { mutableStateOf<String?>(null) }
    val subtitleFiles = remember { mutableStateListOf<Path>() }

    var positionMs by remember { mutableLongStateOf(0L) }
    var lengthMs by remember { mutableLongStateOf(0L) }
    var sliderFrac by remember { mutableFloatStateOf(0f) }
    var playing by remember { mutableStateOf(false) }
    var controlsVisible by remember { mutableStateOf(true) }
    var seeking by remember { mutableStateOf(false) }
    var volume by remember { mutableIntStateOf(80) }
    var muted by remember { mutableStateOf(false) }
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

    val resume = remember(request.itemId, request.season, request.episode) {
        WatchStateStore.resumeFor(request.itemId, request.season, request.episode)
    }
    var resumeApplied by remember { mutableStateOf(false) }
    var resumeShownUntil by remember { mutableLongStateOf(0L) }
    // Position to restore after a quality/server switch (set by playUrl,
    // consumed once the new rendition reports a length). -1 = fresh start.
    var pendingSeekMs by remember { mutableLongStateOf(-1L) }
    // Bumped by the error overlay's Retry to re-run stream resolution.
    var errorAttempt by remember { mutableIntStateOf(0) }

    val playUrl: (String, ResolvedStream) -> Unit = { url, stream ->
        // Quality/server switches keep the live position; only a fresh start
        // (no meaningful position yet) falls through to the resume checkpoint.
        val keepMs = if (lengthMs > 0L && positionMs > 3_000L) positionMs else -1L
        controller.play(url, stream.referer, stream.userAgent, stream.origin)
        positionMs = 0L
        lengthMs = 0L
        sliderFrac = 0f
        resumeApplied = false
        pendingSeekMs = keepMs
        selectedAudioLabel = null
        val sub = stream.subtitles.firstOrNull { it.isDefault } ?: stream.subtitles.firstOrNull()
        sub?.let { s ->
            scope.launch {
                val file = downloadSubtitle(s.url)
                if (file != null) {
                    subtitleFiles.add(Path.of(file))
                    controller.setSubtitleFile(file)
                }
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
    }

    /** Picks a VLC audio ES track matching the chosen HLS rendition. */
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

    fun adjustVolume(delta: Int) {
        volume = (volume + delta).coerceIn(0, 100)
        muted = volume == 0
        controller.setVolume(volume)
        controller.setMute(muted)
        revealControls()
    }

    fun toggleMute() {
        muted = !muted
        controller.setMute(muted)
        revealControls()
    }

    fun togglePlayPause() {
        controller.togglePlayPause()
        revealControls()
    }

    LaunchedEffect(request.itemId, request.season, request.episode, errorAttempt) {
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
        // Focus now (not just after the first stream lands) so Space/F work
        // while the "Finding streams…" overlay is up.
        runCatching { focusRequester.requestFocus() }

        val id = request.itemId
        val isMovie = request.mediaType == "movie"
        val season = request.season
        val episode = request.episode
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
                        repository.saveProgress(itemFrom(request), request.season, request.episode, pos, len)
                    }.onFailure { e -> println("PlayerScreen: progress save failed: $e") }
                }
            }
            delay(600)
        }
    }

    // Auto-hide only while playing and no menu/seek is open (VLC: ~1s).
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
                        repository.saveProgress(itemFrom(request), request.season, request.episode, positionMs, lengthMs)
                    }.onFailure { e -> println("PlayerScreen: final progress save failed: $e") }
                }
            }
            subtitleFiles.forEach { f -> runCatching { Files.deleteIfExists(f) } }
            controller.release()
        }
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(Color.Black)
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
                    Key.DirectionUp -> {
                        adjustVolume(+5)
                        true
                    }
                    Key.DirectionDown -> {
                        adjustVolume(-5)
                        true
                    }
                    else -> false
                }
            },
    ) {
        Surface(color = Color.Black, modifier = Modifier.fillMaxSize()) {}
        SwingPanel(
            factory = { controller.component },
            modifier = Modifier.fillMaxSize(),
            update = {},
        )

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
                                    "Season ${request.season} • Episode ${request.episode}",
                                    color = Color.White.copy(alpha = 0.8f),
                                    fontSize = 13.sp,
                                )
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

        // ── Bottom chrome: seek + transport + menus (VLC order) ─────────────
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
                            "Mute",
                            tint = Color.White,
                        )
                    }
                    Slider(
                        value = volume.toFloat(),
                        onValueChange = { volume = it.toInt(); revealControls() },
                        onValueChangeFinished = {
                            muted = volume == 0
                            controller.setVolume(volume)
                            controller.setMute(muted)
                        },
                        modifier = Modifier.width(100.dp),
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
                        label = if (streams.size > 1) "Server (${selectedIndex + 1}/${streams.size})" else "Server",
                        enabled = streams.isNotEmpty() || failedServers.isNotEmpty(),
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
                            currentStream?.separateAudio == true -> "Quality (adaptive)"
                            qualities.size > 1 -> "Quality (${qualities.size})"
                            else -> "Quality"
                        },
                        enabled = qualities.isNotEmpty() && currentStream?.separateAudio != true,
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

                    PlayerMenu(
                        icon = Icons.Default.ClosedCaption,
                        label = if (subs.isNotEmpty()) "Subtitles (${subs.size})" else "Subtitles",
                        enabled = true,
                        open = openMenu == "subs",
                        onOpenChange = { setMenu("subs", it) },
                        onInteract = { revealControls() },
                    ) { dismiss ->
                        DropdownMenuItem(
                            text = { Text("Off", color = Color.White) },
                            onClick = {
                                dismiss()
                                controller.disableSubtitles()
                            },
                        )
                        subs.forEach { sub ->
                            DropdownMenuItem(
                                text = { Text(sub.label, color = Color.White) },
                                onClick = {
                                    dismiss()
                                    scope.launch {
                                        val f = downloadSubtitle(sub.url)
                                        if (f != null) {
                                            subtitleFiles.add(Path.of(f))
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
                        }
                    }

                    Spacer(Modifier.weight(1f))
                    Text(
                        "Space / Backspace play-pause  •  F fullscreen  •  Esc back",
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

/** Downloads a subtitle to a temp file (VLC peels them off URLs we control only). */
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
