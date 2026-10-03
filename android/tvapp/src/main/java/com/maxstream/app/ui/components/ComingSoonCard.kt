package com.maxstream.app.ui.components

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CalendarToday
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import com.maxstream.app.data.model.MediaItem

// ─────────────────────────────────────────────────────────────────────────────
// Coming Soon card — a port of Dart's `_buildUpcomingCard`
// (lib/screens/maxstream_home_screen.dart): 280×240 backdrop card (height trimmed
// from the phone's 300 so the TV row header stays on screen) with the
// MOVIE/TV + UPCOMING badges, star rating pill, poster thumbnail and the
// title / release date / overview block.
// ─────────────────────────────────────────────────────────────────────────────

val ComingSoonCardWidth: Dp = 280.dp
val ComingSoonCardHeight: Dp = 240.dp

/** Height a row must reserve for a [ComingSoonCard] (card + focus-pop headroom). */
val ComingSoonCardRowHeight: Dp = ComingSoonCardHeight + 8.dp

private val BadgeRed = Color(0xFFE50914)      // KidsTheme.primary (non-kids)
private val BadgeTeal = Color(0xFF00897B)      // "TV" badge
private val BadgePurple = Color(0xFF7B1FA2)    // Colors.purple.shade700
private val AccentPurple = Color(0xFFE040FB)   // Colors.purpleAccent
private val StarAmber = Color(0xFFFFC107)
private val SubtitleWhite = Color(0x8AFFFFFF)  // Colors.white54

@Composable
fun ComingSoonCard(
    item: MediaItem,
    isFocused: Boolean,
    focusRequester: FocusRequester,
    onClick: () -> Unit,
    onFocusChanged: (Boolean) -> Unit,
    onKeyEvent: (KeyEvent) -> Boolean,
    modifier: Modifier = Modifier,
) {
    val scale by animateFloatAsState(
        targetValue = if (isFocused) 1.02f else 1f,
        animationSpec = tween(180),
        label = "comingSoonCardScale",
    )

    val isSeries = item.mediaType == "tv"
    val posterUrl = item.posterUrl
    val backdropUrl = item.backdropUrl.ifEmpty { posterUrl }
    val releaseDate = item.releaseDate
    val overview = item.overview

    Box(
        modifier = modifier
            .padding(horizontal = 7.dp)
            // graphicsLayer, not Modifier.scale: layout-neutral focus pop.
            .graphicsLayer {
                scaleX = scale
                scaleY = scale
            }
            .onKeyEvent(onKeyEvent)
            .focusRequester(focusRequester)
            .onFocusChanged { onFocusChanged(it.hasFocus) }
            // Focus must be registered BEFORE clickable so D-pad Enter fires.
            .focusable()
            .clickable(onClick = onClick)
            .width(ComingSoonCardWidth)
            .height(ComingSoonCardHeight)
            .clip(RoundedCornerShape(12.dp))
            .focusRing(visible = isFocused, cornerRadius = 12.dp),
    ) {
        // ── Backdrop (poster fallback) ───────────────────────────────────────
        if (backdropUrl.isNotEmpty()) {
            AsyncImage(
                model = backdropUrl,
                contentDescription = item.title,
                modifier = Modifier.fillMaxSize(),
                contentScale = ContentScale.Crop,
            )
        } else {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(
                        Brush.linearGradient(
                            listOf(Color(0xFF202020), Color(0xFF1A1A1A)),
                        ),
                    ),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = Icons.Filled.Movie,
                    contentDescription = null,
                    tint = Color.Gray,
                    modifier = Modifier.size(50.dp),
                )
            }
        }

        // ── Bottom gradient scrim ────────────────────────────────────────────
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(
                    Brush.verticalGradient(
                        0.3f to Color.Transparent,
                        1.0f to Color(0xE6000000),
                    ),
                ),
        )

        // ── Poster thumbnail, bottom-left ────────────────────────────────────
        if (posterUrl.isNotEmpty()) {
            AsyncImage(
                model = posterUrl,
                contentDescription = null,
                modifier = Modifier
                    .align(Alignment.BottomStart)
                    .padding(start = 10.dp, bottom = 10.dp)
                    .width(50.dp)
                    .height(72.dp)
                    .clip(RoundedCornerShape(8.dp)),
                contentScale = ContentScale.Crop,
            )
        }

        // ── Badge row: type + UPCOMING ───────────────────────────────────────
        Row(
            modifier = Modifier
                .align(Alignment.TopStart)
                .padding(10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                modifier = Modifier
                    .background(
                        if (isSeries) BadgeTeal else BadgeRed,
                        RoundedCornerShape(4.dp),
                    )
                    .padding(horizontal = 6.dp, vertical = 3.dp),
            ) {
                Text(
                    text = if (isSeries) "TV" else "MOVIE",
                    color = Color.White,
                    fontSize = 9.sp,
                    fontWeight = FontWeight.Bold,
                )
            }
            Spacer(Modifier.width(4.dp))
            Box(
                modifier = Modifier
                    .background(BadgePurple, RoundedCornerShape(6.dp))
                    .padding(horizontal = 8.dp, vertical = 4.dp),
            ) {
                Text(
                    text = "UPCOMING",
                    color = Color.White,
                    fontSize = 9.sp,
                    fontWeight = FontWeight.Bold,
                    letterSpacing = 0.5.sp,
                )
            }
        }

        // ── Rating pill, top-right ───────────────────────────────────────────
        if (item.voteAverage > 0) {
            Row(
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .padding(10.dp)
                    .background(Color(0xB3000000), RoundedCornerShape(6.dp))
                    .padding(horizontal = 6.dp, vertical = 3.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    imageVector = Icons.Filled.Star,
                    contentDescription = null,
                    tint = StarAmber,
                    modifier = Modifier.size(12.dp),
                )
                Spacer(Modifier.width(3.dp))
                Text(
                    text = String.format("%.1f", item.voteAverage),
                    color = Color.White,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Bold,
                )
            }
        }

        // ── Title / release date / overview ──────────────────────────────────
        Column(
            modifier = Modifier
                .align(Alignment.BottomStart)
                .padding(
                    start = if (posterUrl.isNotEmpty()) 72.dp else 10.dp,
                    end = 10.dp,
                    bottom = 10.dp,
                ),
        ) {
            Text(
                text = item.title,
                color = Color.White,
                fontSize = 15.sp,
                fontWeight = FontWeight.Bold,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                lineHeight = 19.sp,
            )
            if (releaseDate.isNotEmpty()) {
                Spacer(Modifier.height(4.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        imageVector = Icons.Filled.CalendarToday,
                        contentDescription = null,
                        tint = AccentPurple,
                        modifier = Modifier.size(11.dp),
                    )
                    Spacer(Modifier.width(4.dp))
                    Text(
                        text = formatReleaseDate(releaseDate),
                        color = AccentPurple,
                        fontSize = 11.sp,
                        fontWeight = FontWeight.W500,
                    )
                }
            }
            if (overview.isNotEmpty()) {
                Spacer(Modifier.height(4.dp))
                Text(
                    text = overview,
                    color = SubtitleWhite,
                    fontSize = 11.sp,
                    lineHeight = 14.sp,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

/** `2026-03-04` → `Mar 4, 2026` (Dart's `_formatReleaseDate`). */
fun formatReleaseDate(date: String): String {
    if (date.isEmpty()) return ""
    val months = listOf(
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    )
    return try {
        val parts = date.split("-")
        val year = parts[0].toInt()
        val month = parts[1].toInt()
        val day = parts[2].toInt()
        "${months[month - 1]} $day, $year"
    } catch (_: Exception) {
        date
    }
}
