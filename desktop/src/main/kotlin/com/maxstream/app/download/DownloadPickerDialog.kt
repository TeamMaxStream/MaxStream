package com.maxstream.app.download

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.maxstream.app.data.model.PlayRequest
import com.maxstream.app.stream.ResolvedStream
import com.maxstream.app.stream.StreamResolver
import com.maxstream.app.stream.parseStreams
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext

/**
 * Resolve every server and present one row per downloadable rendition. The
 * "best" row keeps the master playlist (audio renditions included); explicit
 * quality rows point at that variant's media playlist.
 */
private suspend fun resolveChoices(request: PlayRequest): List<DownloadChoice> = coroutineScope {
    val isMovie = request.mediaType == "movie"
    val fast = async(Dispatchers.IO) {
        runCatching {
            StreamResolver.resolveAll(
                request.itemId,
                isMovie,
                request.season,
                request.episode,
                request.title,
                fast = true,
            )
        }.getOrDefault(emptyList())
    }
    val race = async(Dispatchers.IO) {
        runCatching {
            StreamResolver.resolve(
                request.itemId,
                isMovie,
                request.season,
                request.episode,
                request.title,
            )
        }.getOrNull()
    }
    val streams = parseStreams(fast.await() + listOfNotNull(race.await()))
    streams.flatMap { stream -> choicesFor(stream) }
        .filter { it.url.isNotBlank() }
        .distinctBy { it.url }
        .sortedWith(compareByDescending<DownloadChoice> { it.height }.thenBy { it.server })
}

private fun choicesFor(stream: ResolvedStream): List<DownloadChoice> {
    val type = stream.type.lowercase()
    if (type.contains("dash") || stream.url.contains(".mpd", ignoreCase = true)) {
        return emptyList() // DASH segment maps are not implemented; skip the row.
    }
    val hls = when {
        type.contains("hls") || type.contains("m3u8") -> true
        type.contains("mp4") || type.contains("direct") && !type.contains("m3u8") -> false
        stream.url.contains(".m3u8", ignoreCase = true) -> true
        else -> null
    }
    fun choice(label: String, url: String, height: Int) = DownloadChoice(
        server = stream.server,
        label = label,
        url = url,
        height = height,
        headers = stream.headers,
        hls = hls,
    )

    if (stream.separateAudio) {
        return listOf(choice("Best available (with audio)", stream.url, 0))
    }
    val qualities = stream.qualityMatch().filter { it.url.isNotBlank() }
    if (qualities.isEmpty()) return listOf(choice("Best available", stream.url, 0))
    return qualities.map { q ->
        val label = q.label.takeIf { it.isNotBlank() }
            ?: if (q.height > 0) "${q.height}p" else "Auto"
        choice(label, q.url, q.height)
    }
}

@Composable
fun DownloadPickerDialog(
    request: PlayRequest,
    subtitleLabel: String?,
    onDismiss: () -> Unit,
) {
    var choices by remember(request) { mutableStateOf<List<DownloadChoice>?>(null) }
    var error by remember(request) { mutableStateOf<String?>(null) }
    var selected by remember(request) { mutableStateOf<DownloadChoice?>(null) }
    var attempt by remember(request) { mutableIntStateOf(0) }

    LaunchedEffect(request, attempt) {
        choices = null
        error = null
        selected = null
        val result = runCatching { resolveChoices(request) }
        result.onSuccess { list ->
            choices = list
            selected = list.firstOrNull { it.height in 1..1080 } ?: list.firstOrNull()
            if (list.isEmpty()) error = "No downloadable source was found for this title."
        }.onFailure {
            error = it.message ?: "Could not resolve a download source."
        }
    }

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Surface(
            shape = RoundedCornerShape(18.dp),
            color = MaterialTheme.colorScheme.surface,
            tonalElevation = 8.dp,
            modifier = Modifier.width(540.dp).heightIn(max = 620.dp),
        ) {
            Column(Modifier.padding(22.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        Icons.Default.Download,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.size(24.dp),
                    )
                    Spacer(Modifier.width(10.dp))
                    Column(Modifier.weight(1f)) {
                        Text(
                            "Download",
                            style = MaterialTheme.typography.titleLarge,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Text(
                            request.title + (subtitleLabel?.let { " · $it" } ?: ""),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }

                Spacer(Modifier.height(16.dp))

                val list = choices
                when {
                    error != null -> {
                        Column(
                            Modifier.fillMaxWidth().heightIn(min = 180.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.Center,
                        ) {
                            Text(
                                error.orEmpty(),
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.error,
                                modifier = Modifier.padding(horizontal = 12.dp),
                            )
                            Spacer(Modifier.height(10.dp))
                            TextButton(onClick = { attempt++ }) {
                                Icon(Icons.Default.Refresh, null, modifier = Modifier.size(18.dp))
                                Spacer(Modifier.width(6.dp))
                                Text("Try again")
                            }
                        }
                    }
                    list == null -> {
                        Column(
                            Modifier.fillMaxWidth().heightIn(min = 180.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.Center,
                        ) {
                            CircularProgressIndicator(Modifier.size(28.dp), strokeWidth = 2.dp)
                            Spacer(Modifier.height(12.dp))
                            Text(
                                "Finding downloadable sources…",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                    else -> {
                        LazyColumn(
                            verticalArrangement = Arrangement.spacedBy(6.dp),
                            modifier = Modifier.weight(1f, fill = false).heightIn(max = 400.dp),
                        ) {
                            items(list, key = { it.url }) { choice ->
                                val checked = selected?.url == choice.url
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .background(
                                            if (checked) MaterialTheme.colorScheme.primary.copy(alpha = 0.12f)
                                            else MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f),
                                            RoundedCornerShape(10.dp),
                                        )
                                        .clickable { selected = choice }
                                        .padding(horizontal = 10.dp, vertical = 8.dp),
                                ) {
                                    RadioButton(selected = checked, onClick = { selected = choice })
                                    Column(Modifier.weight(1f)) {
                                        Text(
                                            choice.label,
                                            style = MaterialTheme.typography.bodyMedium,
                                            fontWeight = if (checked) FontWeight.SemiBold else FontWeight.Normal,
                                            maxLines = 1,
                                            overflow = TextOverflow.Ellipsis,
                                        )
                                        Text(
                                            "${choice.server} · ${if (choice.hls == false) "MP4" else "HLS"}",
                                            style = MaterialTheme.typography.labelSmall,
                                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                                            maxLines = 1,
                                            overflow = TextOverflow.Ellipsis,
                                        )
                                    }
                                }
                            }
                        }
                    }
                }

                Spacer(Modifier.height(16.dp))
                Row(
                    Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.End,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    TextButton(onClick = onDismiss) { Text("Cancel") }
                    Spacer(Modifier.width(8.dp))
                    Button(
                        enabled = selected != null,
                        onClick = {
                            val choice = selected ?: return@Button
                            DownloadManager.start(
                                request = request,
                                subtitleLabel = subtitleLabel,
                                server = choice.server,
                                qualityLabel = choice.label,
                                url = choice.url,
                                headers = choice.headers,
                                hls = choice.hls,
                            )
                            onDismiss()
                        },
                    ) {
                        Icon(Icons.Default.Download, null, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(6.dp))
                        Text("Download")
                    }
                }
            }
        }
    }
}
