package com.maxstream.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
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
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.PlaylistPlay
import androidx.compose.material.icons.filled.Bookmark
import androidx.compose.material.icons.filled.BookmarkBorder
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
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
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import com.maxstream.app.core.AppConfig
import com.maxstream.app.data.WatchStateStore
import com.maxstream.app.data.model.Episode
import com.maxstream.app.data.model.MediaDetails
import com.maxstream.app.data.model.MediaItem
import com.maxstream.app.data.model.PlayRequest
import com.maxstream.app.data.repository.MediaRepository
import com.maxstream.app.ui.components.ErrorState
import com.maxstream.app.ui.components.SkeletonBox
import com.maxstream.app.ui.components.appClickable
import com.maxstream.app.ui.components.appFocusRing
import com.maxstream.app.ui.components.posterBrush
import com.maxstream.app.ui.components.ScrollableColumn
import com.maxstream.app.ui.theme.AppColors
import com.maxstream.app.ui.theme.AppSpacing
import java.awt.Desktop
import java.net.URI
import kotlinx.coroutines.launch

/**
 * Desktop details page: backdrop hero with every actionable control on top
 * (play / resume / trailer / watchlist), then overview, genres, cast, watch
 * providers, and — for series — a fully interactive season → episodes browser.
 */
@Composable
fun DetailsScreen(
    itemId: String,
    mediaType: String?,
    repository: MediaRepository,
    onPlay: (PlayRequest) -> Unit,
    onOpen: (MediaItem) -> Unit = {},
) {
    // Details load with explicit failure handling: a thrown repository call
    // used to escape (crash) and a null result spun the spinner forever.
    var detailsError by remember { mutableStateOf(false) }
    var detailsAttempt by remember { mutableIntStateOf(0) }
    val details by produceState<MediaDetails?>(null, itemId, mediaType, detailsAttempt) {
        value = try {
            detailsError = false
            repository.details(itemId, mediaType)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (t: Throwable) {
            detailsError = true
            null
        }
    }
    var watchlistVersion by remember { mutableIntStateOf(0) }
    val scope = rememberCoroutineScope()
    val inWatchlist by produceState(false, itemId, repository, watchlistVersion) {
        value = try {
            repository.isInWatchlist(itemId)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (t: Throwable) {
            false
        }
    }
    var seasonNumber by remember { mutableIntStateOf(1) }
    // `details` must be a key: on first render it's still null, and without
    // it in the keys the episodes block never re-ran after details loaded.
    var episodesLoading by remember { mutableStateOf(false) }
    val episodes by produceState<List<Episode>>(emptyList(), itemId, seasonNumber, details) {
        val d = details
        if (d != null && d.item.mediaType == "tv") {
            episodesLoading = true
            value = try {
                repository.episodes(itemId, seasonNumber).also { episodesLoading = false }
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (t: Throwable) {
                episodesLoading = false
                emptyList()
            }
        }
    }
    val similar by produceState<List<MediaItem>>(emptyList(), itemId, mediaType) {
        value = try {
            repository.recommendations(itemId, mediaType)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (t: Throwable) {
            emptyList()
        }
    }

    val current = details
    if (current == null) {
        Box(Modifier.fillMaxSize()) {
            if (detailsError) {
                ErrorState(
                    title = "Couldn\u2019t load details",
                    message = "The title request failed. Check your connection and try again.",
                    onRetry = { detailsAttempt++ },
                    modifier = Modifier.align(Alignment.Center),
                )
            } else {
                Column(
                    Modifier.align(Alignment.Center),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    SkeletonBox(width = 480.dp, height = 270.dp)
                    Spacer(Modifier.height(AppSpacing.lg))
                    SkeletonBox(width = 320.dp, height = 22.dp)
                    Spacer(Modifier.height(AppSpacing.sm))
                    SkeletonBox(width = 240.dp, height = 16.dp)
                }
            }
        }
        return
    }
    val item = current.item

    Column(Modifier.fillMaxSize()) {
        ScrollableColumn(contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = 24.dp)) {
            // ── Backdrop hero ────────────────────────────────────────────────
            Box(
                Modifier
                    .fillMaxWidth()
                    .height(340.dp)
                    .padding(horizontal = AppSpacing.gutter)
                    .clip(RoundedCornerShape(16.dp))
                    .background(posterBrush(item)),
            ) {
                item.backdropUrl?.let { url ->
                    AsyncImage(
                        model = url,
                        // Decorative — the hero column below announces the title.
                        contentDescription = null,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier.matchParentSize(),
                    )
                }
                Box(
                    Modifier.matchParentSize().background(
                        Brush.verticalGradient(
                            listOf(Color.Transparent, Color.Black.copy(alpha = 0.72f)),
                        ),
                    ),
                )
                Column(
                    Modifier.align(Alignment.BottomStart).padding(AppSpacing.gutter).fillMaxWidth(),
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(
                            if (item.mediaType == "tv") Icons.Default.Tv else Icons.Default.Movie,
                            null,
                            tint = Color.White.copy(alpha = 0.9f),
                            modifier = Modifier.size(18.dp),
                        )
                        Spacer(Modifier.width(6.dp))
                        Text(
                            buildList {
                                add(item.typeLabel)
                                if (item.displayYear.isNotBlank()) add(item.displayYear)
                            }.joinToString("  •  "),
                            color = Color.White.copy(alpha = 0.9f),
                            fontSize = 13.sp,
                        )
                    }
                    Spacer(Modifier.height(6.dp))
                    Text(
                        item.title,
                        style = MaterialTheme.typography.headlineLarge,
                        fontWeight = FontWeight.Bold,
                        color = Color.White,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Spacer(Modifier.height(10.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Default.Star, null, tint = AppColors.ratingGold, modifier = Modifier.size(16.dp))
                        Spacer(Modifier.width(5.dp))
                        Text(
                            "%.1f".format(item.rating),
                            color = Color.White,
                            fontSize = 14.sp,
                            fontWeight = FontWeight.SemiBold,
                        )
                        if (item.genres.isNotEmpty()) {
                            Spacer(Modifier.width(14.dp))
                            Text(
                                item.genres.joinToString("  •  "),
                                color = Color.White.copy(alpha = 0.85f),
                                fontSize = 13.sp,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                }
            }

            // ── Actions ──────────────────────────────────────────────────────
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.padding(horizontal = AppSpacing.gutter, vertical = 14.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                val resume = WatchStateStore.resumeFor(item.id, seasonNumber, 1)

                TextButton(
                    onClick = { onPlay(PlayRequest(item.id, item.mediaType, item.title, seasonNumber, 1)) },
                    modifier = Modifier
                        .background(MaterialTheme.colorScheme.primary, RoundedCornerShape(8.dp))
                        .appFocusRing(cornerRadius = 8.dp, ringColor = Color.White),
                ) {
                    Icon(Icons.Default.PlayArrow, null, tint = MaterialTheme.colorScheme.onPrimary)
                    Spacer(Modifier.width(5.dp))
                    Text("Play", color = MaterialTheme.colorScheme.onPrimary, fontWeight = FontWeight.SemiBold)
                }

                if (resume != null && resume.positionMs > 30_000L) {
                    OutlinedButton(
                        onClick = { onPlay(PlayRequest(item.id, item.mediaType, item.title, resume.season, resume.episode)) },
                    ) {
                        Icon(Icons.AutoMirrored.Filled.PlaylistPlay, null)
                        Spacer(Modifier.width(5.dp))
                        Text("Resume ${fmtTime(resume.positionMs)}")
                    }
                }

                current.trailers.firstOrNull()?.let { trailer ->
                    OutlinedButton(onClick = { openBrowser(trailer.watchUrl) }) {
                        Icon(Icons.Default.Tv, null)
                        Spacer(Modifier.width(5.dp))
                        Text("Trailer")
                    }
                }

                OutlinedButton(onClick = {
                    scope.launch {
                        repository.toggleWatchlist(item)
                        watchlistVersion++
                    }
                }) {
                    Icon(
                        if (inWatchlist) Icons.Default.Bookmark else Icons.Default.BookmarkBorder,
                        null,
                        tint = if (inWatchlist) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface,
                    )
                    Spacer(Modifier.width(5.dp))
                    Text(if (inWatchlist) "In Watchlist" else "Watchlist")
                }
            }

            // ── Overview ─────────────────────────────────────────────────────
            Text(
                item.overview.ifBlank { "No overview available." },
                color = MaterialTheme.colorScheme.onSurface,
                lineHeight = 22.sp,
                fontSize = 15.sp,
                modifier = Modifier.padding(horizontal = AppSpacing.gutter),
                maxLines = 8,
                overflow = TextOverflow.Ellipsis,
            )

            // ── Cast ─────────────────────────────────────────────────────────
            if (current.cast.isNotEmpty()) {
                Spacer(Modifier.height(AppSpacing.xl))
                Text(
                    "Cast",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.padding(horizontal = AppSpacing.gutter),
                )
                Spacer(Modifier.height(10.dp))
                LazyRow(
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = AppSpacing.gutter),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    items(current.cast, key = { it.name }) { member ->
                        Column(
                            Modifier.width(96.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                        ) {
                            Box(
                                Modifier.size(92.dp).clip(CircleShape)
                                    .background(MaterialTheme.colorScheme.surfaceVariant),
                            ) {
                                val url = AppConfig.profileUrl(member.profilePath)
                                if (url != null) {
                                    AsyncImage(
                                        model = url,
                                        contentDescription = member.name,
                                        contentScale = ContentScale.Crop,
                                        modifier = Modifier.fillMaxSize(),
                                    )
                                } else {
                                    Text(
                                        member.name.firstOrNull()?.toString().orEmpty(),
                                        color = Color.White,
                                        fontSize = 28.sp,
                                        fontWeight = FontWeight.Bold,
                                        modifier = Modifier.align(Alignment.Center),
                                    )
                                }
                            }
                            Spacer(Modifier.height(6.dp))
                            Text(
                                member.name,
                                color = MaterialTheme.colorScheme.onSurface,
                                fontSize = 12.sp,
                                fontWeight = FontWeight.Medium,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                            Text(
                                member.character,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                fontSize = 11.sp,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.align(Alignment.CenterHorizontally),
                            )
                        }
                    }
                }
            }

            // ── Where to watch ───────────────────────────────────────────────
            if (current.providers.isNotEmpty()) {
                Spacer(Modifier.height(AppSpacing.xl))
                Text(
                    "Where to watch",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.padding(start = AppSpacing.gutter, bottom = 10.dp),
                )
                Row(
                    horizontalArrangement = Arrangement.spacedBy(14.dp),
                    modifier = Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = AppSpacing.gutter),
                ) {
                    current.providers.forEach { provider ->
                        Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.widthIn(max = 90.dp)) {
                            Box(
                                Modifier.size(56.dp).clip(RoundedCornerShape(12.dp))
                                    .background(MaterialTheme.colorScheme.surfaceVariant),
                                contentAlignment = Alignment.Center,
                            ) {
                                AppConfig.imageUrl("w92", provider.logoPath)?.let { url ->
                                    AsyncImage(
                                        model = url,
                                        contentDescription = provider.name,
                                        contentScale = ContentScale.Crop,
                                        modifier = Modifier.fillMaxSize(),
                                    )
                                } ?: Text(provider.name.firstOrNull()?.toString().orEmpty(), fontWeight = FontWeight.Bold)
                            }
                            Spacer(Modifier.height(6.dp))
                            Text(
                                provider.name,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                fontSize = 11.sp,
                                maxLines = 2,
                                overflow = TextOverflow.Ellipsis,
                                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                            )
                        }
                    }
                }
            }

            // ── Series: seasons + episodes ──────────────────────────────────
            if (item.mediaType == "tv" && current.seasons.isNotEmpty()) {
                Spacer(Modifier.height(AppSpacing.xl))
                Text(
                    "Seasons",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.padding(horizontal = AppSpacing.gutter),
                )
                Spacer(Modifier.height(10.dp))
                Row(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = AppSpacing.gutter),
                ) {
                    current.seasons.forEach { season ->
                        val selectedItem = season.seasonNumber == seasonNumber
                        Box(
                            Modifier
                                .appClickable(cornerRadius = 16.dp) { seasonNumber = season.seasonNumber }
                                .background(
                                    if (selectedItem) MaterialTheme.colorScheme.primary
                                    else MaterialTheme.colorScheme.surfaceVariant,
                                    RoundedCornerShape(16.dp),
                                )
                                .padding(horizontal = 14.dp, vertical = 7.dp),
                        ) {
                            Text(
                                "Season ${season.seasonNumber}",
                                color = if (selectedItem) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurface,
                                fontSize = 13.sp,
                                fontWeight = if (selectedItem) FontWeight.SemiBold else FontWeight.Normal,
                            )
                        }
                    }
                }

                Spacer(Modifier.height(AppSpacing.md))

                when {
                    episodesLoading -> Box(
                        Modifier.fillMaxWidth().height(140.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        CircularProgressIndicator(Modifier.size(26.dp), strokeWidth = 2.dp)
                    }
                    episodes.isEmpty() -> Text(
                        "No episode list available.",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(horizontal = AppSpacing.gutter),
                    )
                    else -> {
                        // Lazy inside a bounded height: a 30-episode season used
                        // to compose every full-size row inside the scroll column.
                        val sortedEpisodes = remember(episodes) { episodes.sortedBy { it.number } }
                        LazyColumn(
                            state = rememberLazyListState(),
                            modifier = Modifier.heightIn(max = 720.dp),
                            verticalArrangement = Arrangement.spacedBy(AppSpacing.sm),
                            contentPadding = androidx.compose.foundation.layout.PaddingValues(
                                horizontal = AppSpacing.gutter,
                                vertical = 4.dp,
                            ),
                        ) {
                            items(sortedEpisodes, key = { it.number }) { ep ->
                                val stillUrl = AppConfig.imageUrl("w300", ep.stillPath)
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .background(MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(14.dp))
                                        .clickable {
                                            onPlay(PlayRequest(item.id, item.mediaType, item.title, seasonNumber, ep.number))
                                        }
                                        .appFocusRing(cornerRadius = 14.dp)
                                        .padding(horizontal = 16.dp, vertical = 14.dp),
                                ) {
                            // 16:9 still — larger card so episodes read as real content.
                            Box(
                                Modifier
                                    .width(196.dp)
                                    .height(110.dp)
                                    .clip(RoundedCornerShape(10.dp))
                                    .background(posterBrush(item)),
                                contentAlignment = Alignment.Center,
                            ) {
                                if (stillUrl != null) {
                                    AsyncImage(
                                        model = stillUrl,
                                        contentDescription = ep.title,
                                        contentScale = ContentScale.Crop,
                                        modifier = Modifier.fillMaxSize(),
                                    )
                                } else {
                                    Icon(
                                        Icons.Default.PlayArrow,
                                        null,
                                        tint = Color.White.copy(alpha = 0.85f),
                                        modifier = Modifier.size(36.dp),
                                    )
                                }
                            }
                            Spacer(Modifier.width(16.dp))
                            Column(Modifier.weight(1f)) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Text(
                                        "E${ep.number}",
                                        color = MaterialTheme.colorScheme.primary,
                                        fontWeight = FontWeight.Bold,
                                        fontSize = 15.sp,
                                    )
                                    if (ep.runtimeMinutes != null) {
                                        Spacer(Modifier.width(10.dp))
                                        Text(
                                            "${ep.runtimeMinutes} min",
                                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                                            fontSize = 12.sp,
                                        )
                                    }
                                    if (!ep.airDate.isNullOrBlank()) {
                                        Spacer(Modifier.width(10.dp))
                                        Text(
                                            ep.airDate,
                                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                                            fontSize = 12.sp,
                                        )
                                    }
                                }
                                Spacer(Modifier.height(4.dp))
                                Text(
                                    ep.title,
                                    color = MaterialTheme.colorScheme.onSurface,
                                    fontWeight = FontWeight.SemiBold,
                                    fontSize = 16.sp,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                                if (ep.overview.isNotBlank()) {
                                    Spacer(Modifier.height(4.dp))
                                    Text(
                                        ep.overview,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        fontSize = 13.sp,
                                        lineHeight = 18.sp,
                                        maxLines = 3,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                }
                            }
                            Spacer(Modifier.width(12.dp))
                            Box(
                                Modifier
                                    .size(48.dp)
                                    .background(MaterialTheme.colorScheme.primary, CircleShape),
                                contentAlignment = Alignment.Center,
                            ) {
                                Icon(
                                    Icons.Default.PlayArrow,
                                    null,
                                    tint = MaterialTheme.colorScheme.onPrimary,
                                    modifier = Modifier.size(28.dp),
                                )
                            }
                        }   // Row
                    }       // items()
                }           // LazyColumn
            }               // else ->
        }                   // when
    }                       // seasons / tv block

            // ── More like this ───────────────────────────────────────────────
            if (similar.isNotEmpty()) {
                Spacer(Modifier.height(AppSpacing.xl))
                Text(
                    "More like this",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.padding(horizontal = AppSpacing.gutter),
                )
                Spacer(Modifier.height(10.dp))
                LazyRow(
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = AppSpacing.gutter),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    items(similar, key = { "${it.mediaType}:${it.id}" }) { rec ->
                        com.maxstream.app.ui.components.PosterCard(
                            item = rec,
                            width = 132.dp,
                            onClick = { onOpen(rec) },
                        )
                    }
                }
            }

            Spacer(Modifier.height(20.dp))
        }
    }
}

private fun fmtTime(ms: Long): String {
    val totalSec = ms / 1000
    val h = totalSec / 3600
    val m = (totalSec % 3600) / 60
    val s = totalSec % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
}

private fun openBrowser(url: String) {
    runCatching { Desktop.getDesktop().browse(URI(url)) }
}