package com.maxstream.app.ui.screens.library

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.navigation.NavController
import coil.compose.AsyncImage
import com.maxstream.app.data.local.WatchEntry
import com.maxstream.app.data.local.WatchProgressRepository
import com.maxstream.app.data.repository.CloudSyncCoordinator
import com.maxstream.app.data.repository.CloudSyncRepository
import com.maxstream.app.ui.components.focusRing
import com.maxstream.app.ui.navigation.Screen
import com.maxstream.app.ui.screens.watchlist.WatchlistScreen
import com.maxstream.app.ui.theme.Background
import com.maxstream.app.ui.theme.Primary
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.roundToInt

private val LIBRARY_SECTIONS = listOf("Watchlist", "History")

// ─────────────────────────────────────────────────────────────────────────────
// Library (Tab 5)
//
// Replaces the old standalone Watchlist tab. The Library owns one top-level
// section row — Watchlist | History — and each section owns its content:
//  - Watchlist keeps the All / Movies / TV Shows filters + poster grid.
//  - Watch History mirrors the phone's grouped, resumable history list.
//
// Focus model:
//  - LEFT from Watchlist or History content opens the sidebar.
//  - UP from the first content row returns to these section chips.
//  - DOWN/ENTER on a chip focuses that section's first target.
// The top chips only change section on ENTER/DOWN, never on focus alone, so
// moving RIGHT between chips cannot cause the content below to steal focus.
// ─────────────────────────────────────────────────────────────────────────────

@Composable
fun LibraryScreen(
    navController: NavController,
    onReturnToSidebar: () -> Unit = {},
    isVisible: Boolean = true,
    focusKey: Int = 0,
    restoreFocusKey: Int = 0,
) {
    var selectedSection by remember { mutableIntStateOf(0) }
    var sectionRowActive by remember { mutableStateOf(false) }
    var contentFocusTick by remember { mutableIntStateOf(0) }
    var sectionFocusRequest by remember { mutableIntStateOf(0) }
    val sectionRequesters = remember { List(LIBRARY_SECTIONS.size) { FocusRequester() } }

    // Returning to this tab from the sidebar / details should land in content,
    // not leave focus parked on the section chips.
    LaunchedEffect(isVisible, focusKey, restoreFocusKey) {
        if (isVisible) sectionRowActive = false
    }

    // Retry the chip focus request so a sync-driven recomposition between the
    // key press and focus landing cannot strand focus in the content.
    LaunchedEffect(sectionFocusRequest) {
        if (sectionFocusRequest == 0) return@LaunchedEffect
        val index = selectedSection.coerceIn(0, LIBRARY_SECTIONS.lastIndex)
        var attempt = 0
        while (attempt < 6) {
            if (attempt > 0) delay(40L * attempt)
            if (runCatching { sectionRequesters[index].requestFocus() }.isSuccess) return@LaunchedEffect
            attempt++
        }
    }

    fun focusSections() {
        sectionRowActive = true
        sectionFocusRequest++
    }

    fun openSection(index: Int) {
        selectedSection = index.coerceIn(0, LIBRARY_SECTIONS.lastIndex)
        sectionRowActive = false
        contentFocusTick++
    }

    fun onSectionKey(index: Int, event: KeyEvent): Boolean {
        if (event.type != KeyEventType.KeyDown) return false
        return when (event.key) {
            Key.DirectionLeft -> {
                if (index == 0) onReturnToSidebar()
                else runCatching { sectionRequesters[index - 1].requestFocus() }
                true
            }
            Key.DirectionRight -> {
                if (index < LIBRARY_SECTIONS.lastIndex) {
                    runCatching { sectionRequesters[index + 1].requestFocus() }
                }
                true
            }
            Key.DirectionDown, Key.Enter, Key.DirectionCenter -> {
                openSection(index)
                true
            }
            Key.DirectionUp -> true
            Key.Back, Key.Escape -> {
                onReturnToSidebar()
                true
            }
            else -> false
        }
    }

    Column(Modifier.fillMaxSize().background(Background)) {
        Column(
            Modifier
                .fillMaxWidth()
                .padding(top = 46.dp, start = 48.dp, end = 48.dp),
        ) {
            Text(
                text = "Library",
                color = Color.White,
                fontSize = 30.sp,
                fontWeight = FontWeight.ExtraBold,
            )
            Spacer(Modifier.height(14.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                LIBRARY_SECTIONS.forEachIndexed { index, label ->
                    LibrarySectionChip(
                        label = label,
                        isSelected = selectedSection == index,
                        focusRequester = sectionRequesters[index],
                        onFocused = { sectionRowActive = true },
                        onSelect = { openSection(index) },
                        onKeyEvent = { onSectionKey(index, it) },
                    )
                }
            }
        }

        Spacer(Modifier.height(16.dp))

        Box(Modifier.fillMaxSize()) {
            when (selectedSection) {
                0 -> WatchlistScreen(
                    navController = navController,
                    onReturnToSidebar = onReturnToSidebar,
                    onUpToSections = { focusSections() },
                    embedded = true,
                    autoFocus = !sectionRowActive,
                    isVisible = isVisible,
                    focusKey = focusKey + contentFocusTick,
                    restoreFocusKey = restoreFocusKey,
                )
                else -> WatchHistoryScreen(
                    navController = navController,
                    onReturnToSidebar = onReturnToSidebar,
                    onUpToSections = { focusSections() },
                    autoFocus = !sectionRowActive,
                    isVisible = isVisible,
                    focusKey = focusKey + contentFocusTick,
                    restoreFocusKey = restoreFocusKey,
                )
            }
        }
    }
}

@Composable
private fun LibrarySectionChip(
    label: String,
    isSelected: Boolean,
    focusRequester: FocusRequester,
    onFocused: () -> Unit,
    onSelect: () -> Unit,
    onKeyEvent: (KeyEvent) -> Boolean,
) {
    var isFocused by remember { mutableStateOf(false) }

    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(20.dp))
            .background(
                when {
                    isSelected -> Primary
                    isFocused -> Color(0xFF2A2A2A)
                    else -> Color(0xFF1A1A1A)
                },
            )
            .border(
                width = if (isFocused) 2.dp else 1.dp,
                color = if (isFocused) Color.White else Color.White.copy(alpha = 0.15f),
                shape = RoundedCornerShape(20.dp),
            )
            .focusRequester(focusRequester)
            .onFocusChanged {
                isFocused = it.hasFocus
                if (it.hasFocus) onFocused()
            }
            .onKeyEvent(onKeyEvent)
            .clickable(onClick = onSelect)
            .padding(horizontal = 24.dp, vertical = 10.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = label,
            color = if (isSelected || isFocused) Color.White else Color.White.copy(alpha = 0.65f),
            fontSize = 15.sp,
            fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Normal,
        )
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Watch History
// ─────────────────────────────────────────────────────────────────────────────

private data class HistoryGroup(
    val key: String,
    val tmdbId: String,
    val isMovie: Boolean,
    val title: String,
    val season: Int,
    val episode: Int,
    val positionSeconds: Long,
    val durationSeconds: Long,
    val isWatched: Boolean,
    val posterUrl: String,
    val timestamp: Long,
    val episodeCount: Int,
) {
    val progress: Float
        get() = when {
            isWatched -> 1f
            durationSeconds > 0 -> (positionSeconds.toFloat() / durationSeconds.toFloat()).coerceIn(0f, 1f)
            else -> 0f
        }
}

@Composable
private fun WatchHistoryScreen(
    navController: NavController,
    onReturnToSidebar: () -> Unit,
    onUpToSections: () -> Unit,
    autoFocus: Boolean,
    isVisible: Boolean,
    focusKey: Int,
    restoreFocusKey: Int,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    var history by remember { mutableStateOf<List<HistoryGroup>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var clearDialog by remember { mutableStateOf(false) }
    var removeTarget by remember { mutableStateOf<HistoryGroup?>(null) }
    var focusedKey by remember { mutableStateOf<String?>(null) }
    var focusedRemoveKey by remember { mutableStateOf<String?>(null) }
    var localRevision by remember { mutableIntStateOf(0) }
    var restoreFocusKeyAfterDialog by remember { mutableStateOf<String?>(null) }

    val cloudRevision by CloudSyncCoordinator.historyRevision.collectAsState()
    val rowRequesters = remember { mutableMapOf<String, FocusRequester>() }
    val removeRequesters = remember { mutableMapOf<String, FocusRequester>() }
    val clearRequester = remember { FocusRequester() }

    fun rowRequester(key: String): FocusRequester =
        rowRequesters.getOrPut(key) { FocusRequester() }

    fun removeRequester(key: String): FocusRequester =
        removeRequesters.getOrPut(key) { FocusRequester() }

    /** Focus requests can run one frame before a newly-composed target is
     * attached; retry briefly instead of silently stranding the remote. */
    fun requestFocus(requester: FocusRequester) {
        if (runCatching { requester.requestFocus() }.isSuccess) return
        scope.launch {
            var attempt = 1
            while (attempt <= 4) {
                delay(40L * attempt)
                if (runCatching { requester.requestFocus() }.isSuccess) return@launch
                attempt++
            }
        }
    }

    LaunchedEffect(isVisible) {
        if (!isVisible) return@LaunchedEffect
        runCatching { CloudSyncRepository.pullToDevice(context) }
    }

    LaunchedEffect(isVisible, cloudRevision, localRevision) {
        if (!isVisible) return@LaunchedEffect
        if (history.isEmpty()) loading = true
        val loaded = withContext(Dispatchers.IO) {
            groupHistory(WatchProgressRepository.history(context))
        }
        history = loaded
        loading = false
        if (focusedKey != null && loaded.none { it.key == focusedKey }) focusedKey = null
        if (focusedRemoveKey != null && loaded.none { it.key == focusedRemoveKey }) {
            focusedRemoveKey = null
        }
    }

    LaunchedEffect(isVisible, loading, autoFocus, focusKey, restoreFocusKey, localRevision, history.size) {
        if (!isVisible || loading || !autoFocus || history.isEmpty()) return@LaunchedEffect
        val target = history.firstOrNull { it.key == focusedKey } ?: history.first()
        focusedKey = target.key
        var attempt = 0
        while (attempt < 6) {
            if (attempt > 0) delay(45L * attempt)
            if (runCatching { rowRequester(target.key).requestFocus() }.isSuccess) {
                focusedRemoveKey = null
                return@LaunchedEffect
            }
            attempt++
        }
    }

    // Dialogs live in their own window; re-seed a row after they close.
    LaunchedEffect(clearDialog, removeTarget) {
        if (clearDialog || removeTarget != null) return@LaunchedEffect
        val key = restoreFocusKeyAfterDialog ?: return@LaunchedEffect
        restoreFocusKeyAfterDialog = null
        delay(160)
        requestFocus(rowRequester(key))
    }

    fun focusRow(index: Int) {
        val target = history.getOrNull(index) ?: return
        focusedKey = target.key
        focusedRemoveKey = null
        requestFocus(rowRequester(target.key))
    }

    fun focusRemove(index: Int) {
        val target = history.getOrNull(index) ?: return
        focusedKey = null
        focusedRemoveKey = target.key
        requestFocus(removeRequester(target.key))
    }

    fun focusClear() {
        focusedKey = null
        focusedRemoveKey = null
        requestFocus(clearRequester)
    }

    fun resume(group: HistoryGroup) {
        navController.navigate(
            Screen.Player.createRoute(
                itemId = group.tmdbId,
                mediaType = if (group.isMovie) "movie" else "tv",
                season = group.season,
                episode = group.episode,
            ),
        )
    }

    fun remove(group: HistoryGroup) {
        restoreFocusKeyAfterDialog = group.key
        scope.launch {
            withContext(Dispatchers.IO) {
                if (group.isMovie) {
                    WatchProgressRepository.removeEntry(
                        context,
                        group.tmdbId,
                        isMovie = true,
                        season = 1,
                        episode = 1,
                    )
                    runCatching {
                        CloudSyncRepository.deleteWatchProgress(
                            context,
                            group.tmdbId,
                            isMovie = true,
                            season = 1,
                            episode = 1,
                        )
                    }
                } else {
                    WatchProgressRepository.removeSeries(context, group.tmdbId)
                    runCatching {
                        CloudSyncRepository.deleteSeriesWatchProgress(context, group.tmdbId)
                    }
                }
            }
            localRevision++
            if (history.size <= 1) onUpToSections()
        }
    }

    fun clearAll() {
        restoreFocusKeyAfterDialog = null
        scope.launch {
            withContext(Dispatchers.IO) {
                WatchProgressRepository.clearAll(context)
                runCatching { CloudSyncRepository.deleteAllWatchProgress(context) }
            }
            localRevision++
            onUpToSections()
        }
    }

    fun onRowKey(index: Int, event: KeyEvent): Boolean {
        if (event.type != KeyEventType.KeyDown) return false
        return when (event.key) {
            Key.DirectionUp -> {
                if (index == 0) focusClear()
                else focusRow(index - 1)
                true
            }
            Key.DirectionDown -> {
                if (index < history.lastIndex) focusRow(index + 1)
                true
            }
            Key.DirectionRight -> {
                focusRemove(index)
                true
            }
            Key.DirectionLeft, Key.Back, Key.Escape -> {
                onReturnToSidebar()
                true
            }
            Key.Enter, Key.DirectionCenter -> {
                history.getOrNull(index)?.let(::resume)
                true
            }
            else -> false
        }
    }

    fun onRemoveKey(index: Int, event: KeyEvent): Boolean {
        if (event.type != KeyEventType.KeyDown) return false
        return when (event.key) {
            Key.DirectionLeft, Key.Back, Key.Escape -> {
                focusRow(index)
                true
            }
            Key.DirectionUp -> {
                if (index == 0) focusClear()
                else focusRemove(index - 1)
                true
            }
            Key.DirectionDown -> {
                if (index < history.lastIndex) focusRemove(index + 1)
                true
            }
            // Right-most target: swallow RIGHT so default focus search cannot
            // jump to an unrelated row.
            Key.DirectionRight -> true
            Key.Enter, Key.DirectionCenter -> {
                history.getOrNull(index)?.let { removeTarget = it }
                true
            }
            else -> false
        }
    }

    fun onClearKey(event: KeyEvent): Boolean {
        if (event.type != KeyEventType.KeyDown) return false
        return when (event.key) {
            Key.DirectionUp, Key.Back, Key.Escape -> {
                onUpToSections()
                true
            }
            Key.DirectionDown -> {
                if (history.isNotEmpty()) focusRow(0)
                true
            }
            Key.DirectionLeft, Key.DirectionRight -> true
            Key.Enter, Key.DirectionCenter -> {
                clearDialog = true
                true
            }
            else -> false
        }
    }

    Column(Modifier.fillMaxSize()) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .padding(start = 48.dp, end = 48.dp, top = 6.dp, bottom = 14.dp),
        ) {
            Column(Modifier.weight(1f)) {
                Text(
                    text = "Watch History",
                    color = Color.White,
                    fontSize = 22.sp,
                    fontWeight = FontWeight.Bold,
                )
                Text(
                    text = if (loading) "Syncing history…" else
                        "${history.size} title${if (history.size == 1) "" else "s"} · synced with phone and desktop",
                    color = Color.White.copy(alpha = 0.55f),
                    fontSize = 13.sp,
                )
            }
            if (history.isNotEmpty() && !loading) {
                ClearHistoryButton(
                    focusRequester = clearRequester,
                    onKeyEvent = ::onClearKey,
                ) { clearDialog = true }
            }
        }

        when {
            loading -> Box(Modifier.fillMaxWidth().weight(1f), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = Primary)
            }

            history.isEmpty() -> Box(Modifier.fillMaxWidth().weight(1f), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Icon(
                        Icons.Default.History,
                        contentDescription = null,
                        tint = Color.White.copy(alpha = 0.35f),
                        modifier = Modifier.size(64.dp),
                    )
                    Spacer(Modifier.height(16.dp))
                    Text("No Watch History", color = Color.White, fontSize = 19.sp, fontWeight = FontWeight.SemiBold)
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "Movies and episodes you play on any device appear here.",
                        color = Color.White.copy(alpha = 0.5f),
                        fontSize = 14.sp,
                    )
                }
            }

            else -> LazyColumn(
                contentPadding = PaddingValues(start = 48.dp, end = 48.dp, bottom = 56.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
                modifier = Modifier.fillMaxSize(),
            ) {
                itemsIndexed(history, key = { _, item -> item.key }) { index, item ->
                    HistoryRow(
                        group = item,
                        isFocused = focusedKey == item.key,
                        isRemoveFocused = focusedRemoveKey == item.key,
                        focusRequester = rowRequester(item.key),
                        removeFocusRequester = removeRequester(item.key),
                        onFocused = { focused ->
                            if (focused) {
                                focusedKey = item.key
                                focusedRemoveKey = null
                            }
                        },
                        onRemoveFocused = { focused ->
                            if (focused) {
                                focusedRemoveKey = item.key
                                focusedKey = null
                            }
                        },
                        onKeyEvent = { onRowKey(index, it) },
                        onRemoveKeyEvent = { onRemoveKey(index, it) },
                        onResume = { resume(item) },
                        onRemove = { removeTarget = item },
                    )
                }
            }
        }
    }

    if (clearDialog) {
        AlertDialog(
            onDismissRequest = { clearDialog = false },
            title = { Text("Clear watch history?") },
            text = {
                Text(
                    "This removes every resume point on the TV, phone, and desktop. " +
                        "Your watchlist and downloads are not affected.",
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    clearDialog = false
                    clearAll()
                }) { Text("Clear history", color = Color(0xFFE50914)) }
            },
            dismissButton = {
                TextButton(onClick = {
                    clearDialog = false
                    restoreFocusKeyAfterDialog = history.firstOrNull()?.key
                }) { Text("Cancel") }
            },
        )
    }

    removeTarget?.let { target ->
        AlertDialog(
            onDismissRequest = {
                removeTarget = null
                restoreFocusKeyAfterDialog = target.key
            },
            title = { Text("Remove from history?") },
            text = {
                Text(
                    if (target.isMovie) {
                        "“${target.title}” will be removed from history on the TV, phone, and desktop."
                    } else {
                        "“${target.title}” and all of its episodes will be removed from history on the TV, phone, and desktop."
                    },
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    removeTarget = null
                    remove(target)
                }) { Text("Remove", color = Color(0xFFE50914)) }
            },
            dismissButton = {
                TextButton(onClick = {
                    removeTarget = null
                    restoreFocusKeyAfterDialog = target.key
                }) { Text("Cancel") }
            },
        )
    }
}

@Composable
private fun ClearHistoryButton(
    focusRequester: FocusRequester,
    onKeyEvent: (KeyEvent) -> Boolean,
    onClick: () -> Unit,
) {
    var isFocused by remember { mutableStateOf(false) }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .clip(RoundedCornerShape(12.dp))
            .background(if (isFocused) Color(0xFF3A1F22) else Color(0xFF211A1A))
            .focusRing(isFocused, 12.dp)
            .focusRequester(focusRequester)
            .onFocusChanged { isFocused = it.hasFocus }
            .onKeyEvent(onKeyEvent)
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 9.dp),
    ) {
        Icon(Icons.Default.Delete, null, tint = Color(0xFFE50914), modifier = Modifier.size(17.dp))
        Spacer(Modifier.width(7.dp))
        Text("Clear history", color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun HistoryRow(
    group: HistoryGroup,
    isFocused: Boolean,
    isRemoveFocused: Boolean,
    focusRequester: FocusRequester,
    removeFocusRequester: FocusRequester,
    onFocused: (Boolean) -> Unit,
    onRemoveFocused: (Boolean) -> Unit,
    onKeyEvent: (KeyEvent) -> Boolean,
    onRemoveKeyEvent: (KeyEvent) -> Boolean,
    onResume: () -> Unit,
    onRemove: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(if (isFocused) Color(0xFF262626) else Color(0xFF1A1A1A))
            .focusRing(isFocused, 14.dp)
            .focusRequester(focusRequester)
            .onFocusChanged { onFocused(it.hasFocus) }
            .onKeyEvent(onKeyEvent)
            .clickable(onClick = onResume)
            .padding(12.dp),
    ) {
        Box(
            Modifier
                .width(62.dp)
                .height(92.dp)
                .clip(RoundedCornerShape(8.dp))
                .background(Color(0xFF2A2A2A)),
            contentAlignment = Alignment.Center,
        ) {
            if (group.posterUrl.isNotBlank()) {
                AsyncImage(
                    model = group.posterUrl,
                    contentDescription = group.title,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize(),
                )
            } else {
                Icon(
                    Icons.Default.PlayArrow,
                    null,
                    tint = Color.White.copy(alpha = 0.4f),
                    modifier = Modifier.size(26.dp),
                )
            }
        }

        Spacer(Modifier.width(14.dp))

        Column(Modifier.weight(1f)) {
            Text(
                text = group.title.ifBlank { "Title ${group.tmdbId}" },
                color = Color.White,
                fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Spacer(Modifier.height(3.dp))
            Text(
                text = when {
                    group.isMovie -> "Movie"
                    group.episodeCount > 1 ->
                        "S${group.season} E${group.episode} · ${group.episodeCount} episodes"
                    else -> "S${group.season} E${group.episode}"
                },
                color = Color.White.copy(alpha = 0.55f),
                fontSize = 13.sp,
            )
            Spacer(Modifier.height(7.dp))
            LinearProgressIndicator(
                progress = { group.progress },
                modifier = Modifier.fillMaxWidth().height(4.dp).clip(RoundedCornerShape(2.dp)),
                color = Primary,
                trackColor = Color.White.copy(alpha = 0.14f),
            )
            Spacer(Modifier.height(6.dp))
            Text(
                text = buildString {
                    if (group.isWatched) append("Watched")
                    else append("${(group.progress * 100).roundToInt()}% watched")
                    append(" · ")
                    append(relativeHistoryTime(group.timestamp))
                },
                color = Color.White.copy(alpha = 0.5f),
                fontSize = 12.sp,
            )
        }

        Spacer(Modifier.width(14.dp))

        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .clip(RoundedCornerShape(10.dp))
                .background(if (isRemoveFocused) Color(0xFF3A1F22) else Color(0xFF232323))
                .focusRing(isRemoveFocused, 10.dp)
                .focusRequester(removeFocusRequester)
                .onFocusChanged { onRemoveFocused(it.hasFocus) }
                .onKeyEvent(onRemoveKeyEvent)
                .clickable(onClick = onRemove)
                .padding(horizontal = 13.dp, vertical = 8.dp),
        ) {
            Icon(
                Icons.Default.Delete,
                contentDescription = "Remove from history",
                tint = if (isRemoveFocused) Color(0xFFE50914) else Color.White.copy(alpha = 0.7f),
                modifier = Modifier.size(16.dp),
            )
            Spacer(Modifier.width(6.dp))
            Text(
                "Remove",
                color = if (isRemoveFocused) Color.White else Color.White.copy(alpha = 0.7f),
                fontSize = 13.sp,
            )
        }
    }
}

private fun groupHistory(entries: List<WatchEntry>): List<HistoryGroup> {
    val groups = mutableListOf<HistoryGroup>()
    val series = LinkedHashMap<String, MutableList<WatchEntry>>()

    for (entry in entries) {
        if (entry.isMovie) {
            groups += entry.toGroup(episodeCount = 1)
        } else if (entry.tmdbId.isNotBlank()) {
            series.getOrPut(entry.tmdbId) { mutableListOf() }.add(entry)
        }
    }

    for ((tmdbId, episodes) in series) {
        val latest = episodes.maxByOrNull { it.timestamp } ?: continue
        val episodeCount = episodes
            .map { "${it.season}:${it.episode}" }
            .toSet()
            .size
        val title = latest.seriesTitle.ifBlank {
            latest.title.replaceFirst(Regex("\\s*-\\s*S\\d+E\\d+.*$", RegexOption.IGNORE_CASE), "")
        }
        groups += HistoryGroup(
            key = "tv_$tmdbId",
            tmdbId = tmdbId,
            isMovie = false,
            title = title.ifBlank { latest.title },
            season = latest.season,
            episode = latest.episode,
            positionSeconds = latest.positionSeconds,
            durationSeconds = latest.durationSeconds,
            isWatched = latest.isWatched,
            posterUrl = latest.coverUrl,
            timestamp = latest.timestamp,
            episodeCount = episodeCount,
        )
    }

    return groups.sortedByDescending { it.timestamp }
}

private fun WatchEntry.toGroup(episodeCount: Int): HistoryGroup = HistoryGroup(
    key = "movie_$tmdbId",
    tmdbId = tmdbId,
    isMovie = true,
    title = title.ifBlank { seriesTitle },
    season = 1,
    episode = 1,
    positionSeconds = positionSeconds,
    durationSeconds = durationSeconds,
    isWatched = isWatched,
    posterUrl = coverUrl,
    timestamp = timestamp,
    episodeCount = episodeCount,
)

private fun relativeHistoryTime(timestamp: Long): String {
    if (timestamp <= 0L) return "Earlier"
    val diff = (System.currentTimeMillis() - timestamp).coerceAtLeast(0L)
    val minutes = diff / 60_000L
    val hours = diff / 3_600_000L
    val days = diff / 86_400_000L
    return when {
        minutes < 1 -> "Just now"
        minutes < 60 -> "$minutes minute${if (minutes == 1L) "" else "s"} ago"
        hours < 24 -> "$hours hour${if (hours == 1L) "" else "s"} ago"
        days < 7 -> "$days day${if (days == 1L) "" else "s"} ago"
        days < 30 -> "${days / 7} week${if (days / 7 == 1L) "" else "s"} ago"
        else -> "${days / 30} month${if (days / 30 == 1L) "" else "s"} ago"
    }
}
