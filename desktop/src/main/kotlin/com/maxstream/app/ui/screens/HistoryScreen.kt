package com.maxstream.app.ui.screens

import androidx.compose.foundation.background
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
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import com.maxstream.app.core.AppConfig
import com.maxstream.app.data.KidsMode
import com.maxstream.app.data.WatchStateStore
import com.maxstream.app.data.cloud.CloudSync
import com.maxstream.app.data.model.MediaItem
import com.maxstream.app.data.model.PlayRequest
import com.maxstream.app.data.repository.TmdbRepository
import com.maxstream.app.ui.components.EmptyState
import com.maxstream.app.ui.theme.AppSpacing
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private data class HistoryEntry(
    val state: WatchStateStore.WatchState,
    val item: MediaItem,
)

/**
 * Full watch history (Continue Watching is only the Home rail). Entries come
 * from the same local store the player writes, so this works offline and is
 * merged with cloud history on sign-in. Kids profiles only see kid-safe rows.
 */
@Composable
fun HistoryScreen(
    revision: Int,
    onPlay: (PlayRequest) -> Unit,
) {
    var localRevision by remember { mutableIntStateOf(0) }
    var clearAll by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val entries by produceState<List<HistoryEntry>>(
        initialValue = emptyList(),
        revision,
        localRevision,
        KidsMode.isActive,
    ) {
        value = withContext(Dispatchers.IO) { loadHistory() }
    }

    fun remove(entry: HistoryEntry) {
        WatchStateStore.clear(entry.state.itemId, entry.state.season, entry.state.episode)
        scope.launch(Dispatchers.IO) {
            if (CloudSync.isSynced) CloudSync.clearWatchHistory(entry.state)
        }
        localRevision++
    }

    Column(Modifier.fillMaxSize().padding(horizontal = AppSpacing.gutter)) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth().padding(top = 20.dp, bottom = 6.dp),
        ) {
            Column(Modifier.weight(1f)) {
                Text(
                    "History",
                    style = MaterialTheme.typography.headlineMedium,
                    fontWeight = FontWeight.Bold,
                )
                Text(
                    "${entries.size} title${if (entries.size == 1) "" else "s"} · resume anything you started",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            if (entries.isNotEmpty()) {
                TextButton(onClick = { clearAll = true }) {
                    Icon(Icons.Default.Delete, null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("Clear history")
                }
            }
        }

        Spacer(Modifier.height(10.dp))

        if (entries.isEmpty()) {
            EmptyState(
                title = "Nothing watched yet",
                message = "Movies and episodes you play will show up here with their resume position.",
                icon = Icons.Default.History,
            )
        } else {
            LazyColumn(
                verticalArrangement = Arrangement.spacedBy(10.dp),
                contentPadding = PaddingValues(bottom = 28.dp),
                modifier = Modifier.fillMaxSize(),
            ) {
                items(entries, key = { "${it.state.itemId}-${it.state.season}-${it.state.episode}" }) { entry ->
                    HistoryRow(entry = entry, onPlay = onPlay, onRemove = { remove(entry) })
                }
            }
        }
    }

    if (clearAll) {
        AlertDialog(
            onDismissRequest = { clearAll = false },
            title = { Text("Clear watch history?") },
            text = {
                Text(
                    "This removes every resume point, including synced entries on your other devices. Downloads are not deleted.",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    scope.launch {
                        withContext(Dispatchers.IO) {
                            val all = WatchStateStore.all()
                            if (CloudSync.isSynced) {
                                all.forEach { CloudSync.clearWatchHistory(it) }
                            }
                            WatchStateStore.clearAll()
                        }
                        clearAll = false
                        localRevision++
                    }
                }) { Text("Clear all", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { clearAll = false }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun HistoryRow(
    entry: HistoryEntry,
    onPlay: (PlayRequest) -> Unit,
    onRemove: () -> Unit,
) {
    val s = entry.state
    Surface(
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f),
        shape = RoundedCornerShape(14.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(12.dp),
        ) {
            val poster = AppConfig.posterUrl(entry.item.posterPath ?: s.posterPath)
            Box(
                Modifier
                    .width(56.dp)
                    .height(82.dp)
                    .clip(RoundedCornerShape(8.dp))
                    .background(Color(0xFF23252C)),
                contentAlignment = Alignment.Center,
            ) {
                if (poster != null) {
                    AsyncImage(
                        model = poster,
                        contentDescription = s.title,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier.fillMaxSize(),
                    )
                } else {
                    Icon(
                        Icons.Default.History,
                        null,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(24.dp),
                    )
                }
            }
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    s.title.ifBlank { entry.item.title },
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    if (s.mediaType == "tv") "Season ${s.season} · Episode ${s.episode}" else "Movie",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.height(7.dp))
                LinearProgressIndicator(
                    progress = { s.progress },
                    modifier = Modifier.fillMaxWidth().height(4.dp).clip(RoundedCornerShape(2.dp)),
                )
                Spacer(Modifier.height(5.dp))
                Text(
                    "${fmtHistoryTime(s.positionMs)} of ${fmtHistoryTime(s.lengthMs)} · ${historyDate(s.updatedAt)}",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Spacer(Modifier.width(10.dp))
            Button(
                onClick = {
                    onPlay(
                        PlayRequest(
                            itemId = s.itemId,
                            mediaType = s.mediaType,
                            title = s.title.ifBlank { entry.item.title },
                            season = s.season,
                            episode = s.episode,
                            posterPath = s.posterPath ?: entry.item.posterPath,
                        ),
                    )
                },
            ) {
                Icon(Icons.Default.PlayArrow, null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(4.dp))
                Text(if (s.positionMs > 0L) "Resume" else "Play")
            }
            IconButton(onClick = onRemove) {
                Icon(Icons.Default.Delete, "Remove from history", tint = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

private suspend fun loadHistory(): List<HistoryEntry> {
    return WatchStateStore.all().mapNotNull { state ->
        val needsMetadata = state.title.isBlank() || state.posterPath == null || state.genreIds.isEmpty()
        val hydrated = if (needsMetadata || KidsMode.isActive) {
            runCatching { TmdbRepository.details(state.itemId, state.mediaType) }.getOrNull()?.item
        } else null
        val item = MediaItem(
            id = state.itemId,
            mediaType = state.mediaType,
            title = state.title.ifBlank { hydrated?.title ?: "Title ${state.itemId}" },
            overview = hydrated?.overview.orEmpty(),
            year = state.year ?: hydrated?.year,
            genres = hydrated?.genres.orEmpty(),
            genreIds = state.genreIds.ifEmpty { hydrated?.genreIds.orEmpty() },
            rating = state.rating.takeIf { it > 0.0 } ?: hydrated?.rating ?: 0.0,
            posterPath = state.posterPath ?: hydrated?.posterPath,
            backdropPath = state.backdropPath ?: hydrated?.backdropPath,
        )
        if (KidsMode.isActive && !KidsMode.isKidFriendly(item)) null
        else HistoryEntry(state, item)
    }
}

private fun fmtHistoryTime(ms: Long): String {
    if (ms <= 0L) return "0:00"
    val totalSec = ms / 1000
    val h = totalSec / 3600
    val m = (totalSec % 3600) / 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, totalSec % 60) else "%d:%02d".format(m, totalSec % 60)
}

private fun historyDate(epochMs: Long): String {
    if (epochMs <= 0L) return "Earlier"
    val then = java.time.Instant.ofEpochMilli(epochMs).atZone(java.time.ZoneId.systemDefault()).toLocalDate()
    val today = java.time.LocalDate.now()
    return when (then) {
        today -> "Today"
        today.minusDays(1) -> "Yesterday"
        else -> "%d %s".format(then.dayOfMonth, then.month.name.lowercase().replaceFirstChar { it.uppercase() }.take(3))
    }
}
