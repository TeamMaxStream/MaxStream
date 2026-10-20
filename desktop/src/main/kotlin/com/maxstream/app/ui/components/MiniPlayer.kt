package com.maxstream.app.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.OpenInFull
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
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
import com.maxstream.app.player.PlaybackSession
import kotlinx.coroutines.delay

/**
 * In-app mini-player. Playback keeps running in the shared libmpv session while
 * the user browses; expanding pushes the full player again without restarting.
 * The video frame is an ordinary Compose layer, so the mini-player can show a
 * live preview and sit above the rest of the shell.
 */
@Composable
fun MiniPlayer(
    modifier: Modifier = Modifier,
    onExpand: (PlayRequest) -> Unit,
) {
    val current = PlaybackSession.nowPlaying ?: return
    val controller = PlaybackSession.controller
    var playing by remember { mutableStateOf(runCatching { controller.isPlaying }.getOrDefault(true)) }
    var fraction by remember { mutableFloatStateOf(0f) }

    LaunchedEffect(current) {
        while (true) {
            playing = runCatching { controller.isPlaying }.getOrDefault(false)
            val length = runCatching { controller.length() }.getOrDefault(0L)
            val position = runCatching { controller.time() }.getOrDefault(0L)
            fraction = if (length > 0L) (position.toFloat() / length).coerceIn(0f, 1f) else 0f
            delay(700)
        }
    }

    val subtitle = buildString {
        if (current.local) append("Offline") else {
            append(current.server)
            if (current.quality.isNotBlank()) append(" · ").append(current.quality)
        }
        if (current.request.mediaType == "tv") {
            append(" · S").append(current.request.season)
            append(" E").append(current.request.episode)
        }
    }
    val poster = AppConfig.posterUrl(current.request.posterPath)

    Surface(
        modifier = modifier
            .width(430.dp)
            .appClickable(cornerRadius = 16.dp) { onExpand(current.request) },
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.surface,
        tonalElevation = 12.dp,
        shadowElevation = 18.dp,
    ) {
        Column {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.padding(10.dp),
            ) {
                Box(
                    Modifier
                        .width(112.dp)
                        .height(63.dp)
                        .clip(RoundedCornerShape(9.dp))
                        .background(Color(0xFF23252C)),
                    contentAlignment = Alignment.Center,
                ) {
                    if (poster != null) {
                        AsyncImage(
                            model = poster,
                            contentDescription = null,
                            contentScale = ContentScale.Crop,
                            modifier = Modifier.fillMaxSize(),
                        )
                    } else {
                        Icon(
                            if (current.local) Icons.Default.Download else Icons.Default.PlayArrow,
                            null,
                            tint = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.size(24.dp),
                        )
                    }
                    // Live preview; transparent until the first frame arrives so
                    // the poster remains the fallback while buffering.
                    PlayerSurface(Modifier.fillMaxSize(), background = Color.Transparent)
                }
                Spacer(Modifier.width(11.dp))
                Column(Modifier.weight(1f)) {
                    Text(
                        current.request.title,
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Spacer(Modifier.height(2.dp))
                    Text(
                        subtitle,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        fontSize = 11.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Spacer(Modifier.height(6.dp))
                    LinearProgressIndicator(
                        progress = { fraction },
                        modifier = Modifier.fillMaxWidth().height(3.dp).clip(RoundedCornerShape(2.dp)),
                    )
                }
                Spacer(Modifier.width(4.dp))
                IconButton(onClick = { controller.togglePlayPause() }) {
                    Icon(
                        if (playing) Icons.Default.Pause else Icons.Default.PlayArrow,
                        contentDescription = if (playing) "Pause" else "Play",
                        tint = MaterialTheme.colorScheme.primary,
                    )
                }
                IconButton(onClick = { onExpand(current.request) }) {
                    Icon(
                        Icons.Default.OpenInFull,
                        contentDescription = "Open player",
                        tint = MaterialTheme.colorScheme.onSurface,
                    )
                }
                IconButton(onClick = { PlaybackSession.stop() }) {
                    Icon(
                        Icons.Default.Close,
                        contentDescription = "Close player",
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}
