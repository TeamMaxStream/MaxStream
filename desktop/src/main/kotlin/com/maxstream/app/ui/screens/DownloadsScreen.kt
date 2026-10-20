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
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.FolderOpen
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
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
import com.maxstream.app.data.model.PlayRequest
import com.maxstream.app.download.DownloadItem
import com.maxstream.app.download.DownloadManager
import com.maxstream.app.download.DownloadStatus
import com.maxstream.app.download.DownloadStore
import com.maxstream.app.ui.components.EmptyState
import com.maxstream.app.ui.theme.AppSpacing
import java.awt.Desktop
import java.io.File

/**
 * Offline library. Downloads are per profile; the files live under
 * ~/.maxstream/downloads and play through the same mpv screen with stream
 * resolution bypassed.
 */
@Composable
fun DownloadsScreen(onPlay: (PlayRequest) -> Unit) {
    val items = DownloadManager.itemsForActiveProfile()
    var deleteTarget by remember { mutableStateOf<DownloadItem?>(null) }

    Column(Modifier.fillMaxSize().padding(horizontal = AppSpacing.gutter)) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth().padding(top = 20.dp, bottom = 6.dp),
        ) {
            Column(Modifier.weight(1f)) {
                Text(
                    "Downloads",
                    style = MaterialTheme.typography.headlineMedium,
                    fontWeight = FontWeight.Bold,
                )
                Text(
                    "${items.size} title${if (items.size == 1) "" else "s"} · ${DownloadManager.storagePath}",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (items.any { it.status == DownloadStatus.COMPLETED }) {
                TextButton(onClick = { DownloadManager.clearCompleted() }) {
                    Icon(Icons.Default.Delete, null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("Clear completed")
                }
            }
            TextButton(onClick = {
                runCatching { Desktop.getDesktop().open(File(DownloadManager.storagePath)) }
            }) {
                Icon(Icons.Default.FolderOpen, null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(6.dp))
                Text("Open folder")
            }
        }

        Spacer(Modifier.height(10.dp))

        if (items.isEmpty()) {
            EmptyState(
                title = "No downloads yet",
                message = "Open any movie or episode and choose Download to save it for offline playback.",
                icon = Icons.Default.Download,
            )
        } else {
            LazyColumn(
                verticalArrangement = Arrangement.spacedBy(12.dp),
                contentPadding = PaddingValues(bottom = 28.dp),
                modifier = Modifier.fillMaxSize(),
            ) {
                items(items, key = { it.id }) { item ->
                    DownloadRow(
                        item = item,
                        onPlay = onPlay,
                        onDelete = { deleteTarget = item },
                    )
                }
            }
        }
    }

    deleteTarget?.let { item ->
        AlertDialog(
            onDismissRequest = { deleteTarget = null },
            title = { Text("Delete download?") },
            text = {
                Text(
                    "${item.request.title}${item.subtitleLabel?.let { " · $it" } ?: ""} will be removed from disk.",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    DownloadManager.remove(item.id)
                    deleteTarget = null
                }) { Text("Delete", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = {
                TextButton(onClick = { deleteTarget = null }) { Text("Keep") }
            },
        )
    }
}

@Composable
private fun DownloadRow(
    item: DownloadItem,
    onPlay: (PlayRequest) -> Unit,
    onDelete: () -> Unit,
) {
    Surface(
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f),
        shape = RoundedCornerShape(14.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(12.dp),
        ) {
            val poster = AppConfig.posterUrl(item.request.posterPath)
            Box(
                Modifier
                    .width(64.dp)
                    .height(94.dp)
                    .clip(RoundedCornerShape(8.dp))
                    .background(Color(0xFF23252C)),
                contentAlignment = Alignment.Center,
            ) {
                if (poster != null) {
                    AsyncImage(
                        model = poster,
                        contentDescription = item.request.title,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier.fillMaxSize(),
                    )
                } else {
                    Icon(
                        Icons.Default.Download,
                        null,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(26.dp),
                    )
                }
            }
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    item.request.title,
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    item.subtitleLabel
                        ?: if (item.request.mediaType == "tv") "Season ${item.request.season} · Episode ${item.request.episode}" else "Movie",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                )
                Text(
                    "${item.server} · ${item.qualityLabel}",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Spacer(Modifier.height(8.dp))
                when (item.status) {
                    DownloadStatus.QUEUED, DownloadStatus.DOWNLOADING -> {
                        LinearProgressIndicator(
                            progress = { item.fraction },
                            modifier = Modifier.fillMaxWidth().height(5.dp).clip(RoundedCornerShape(3.dp)),
                        )
                        Spacer(Modifier.height(5.dp))
                        Text(
                            item.progressLabel(),
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    DownloadStatus.PAUSED -> {
                        LinearProgressIndicator(
                            progress = { item.fraction },
                            modifier = Modifier.fillMaxWidth().height(5.dp).clip(RoundedCornerShape(3.dp)),
                        )
                        Spacer(Modifier.height(5.dp))
                        Text(
                            item.progressLabel(),
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    DownloadStatus.FAILED -> Text(
                        item.progressLabel(),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.error,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                    DownloadStatus.COMPLETED -> Text(
                        item.progressLabel(),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.primary,
                    )
                }
            }
            Spacer(Modifier.width(10.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                when (item.status) {
                    DownloadStatus.COMPLETED -> {
                        Button(
                            onClick = {
                                val path = DownloadManager.playablePath(item) ?: return@Button
                                onPlay(item.request.copy(localPath = path))
                            },
                        ) {
                            Icon(Icons.Default.PlayArrow, null, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(4.dp))
                            Text("Play")
                        }
                        Spacer(Modifier.width(4.dp))
                        IconButton(onClick = onDelete) {
                            Icon(Icons.Default.Delete, "Delete", tint = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                    DownloadStatus.QUEUED, DownloadStatus.DOWNLOADING -> {
                        CircularProgressIndicator(Modifier.size(22.dp), strokeWidth = 2.dp)
                        Spacer(Modifier.width(8.dp))
                        IconButton(onClick = { DownloadManager.pause(item.id) }) {
                            Icon(Icons.Default.Pause, "Pause")
                        }
                        IconButton(onClick = { DownloadManager.cancel(item.id) }) {
                            Icon(Icons.Default.Close, "Cancel", tint = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                    DownloadStatus.PAUSED -> {
                        Button(onClick = { DownloadManager.resume(item.id) }) {
                            Icon(Icons.Default.PlayArrow, null, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(4.dp))
                            Text("Resume")
                        }
                        IconButton(onClick = onDelete) {
                            Icon(Icons.Default.Delete, "Delete", tint = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                    DownloadStatus.FAILED -> {
                        Button(onClick = { DownloadManager.retry(item.id) }) {
                            Icon(Icons.Default.Refresh, null, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(4.dp))
                            Text("Retry")
                        }
                        IconButton(onClick = onDelete) {
                            Icon(Icons.Default.Delete, "Delete", tint = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
            }
        }
    }
}
