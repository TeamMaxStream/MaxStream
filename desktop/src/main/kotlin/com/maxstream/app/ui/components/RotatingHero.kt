package com.maxstream.app.ui.components

import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsHoveredAsState
import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.onPointerEvent
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import com.maxstream.app.data.model.MediaItem
import com.maxstream.app.ui.theme.AppColors
import com.maxstream.app.ui.theme.AppSpacing
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive

/**
 * Full-bleed rotating hero (port of mobile lib/widgets/hero_banner.dart):
 * Crossfade carousel over trending backdrops, left+bottom gradients, title,
 * metadata row, overview, Play / More info actions, and page dots. Auto-advances
 * every 6s like the phone app.
 */
@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
@Composable
fun RotatingHero(
    items: List<MediaItem>,
    onPlay: (MediaItem) -> Unit,
    onOpen: (MediaItem) -> Unit,
    modifier: Modifier = Modifier,
) {
    if (items.isEmpty()) return
    var index by remember { mutableIntStateOf(0) }
    val current = items[index.coerceIn(0, items.lastIndex)]

    // Pause auto-advance while the user is interacting (hover) or while the
    // hero has scrolled out of view — the old loop kept crossfading forever,
    // even for an offscreen hero.
    var hovered by remember { mutableStateOf(false) }
    var onScreen by remember { mutableStateOf(true) }

    LaunchedEffect(items.size, hovered, onScreen) {
        if (items.size < 2) return@LaunchedEffect
        while (isActive && !hovered && onScreen) {
            delay(6_000L)
            if (!hovered && onScreen) index = (index + 1) % items.size
        }
    }

    Box(
        modifier
            .fillMaxWidth()
            .height(340.dp)
            .onPointerEvent(PointerEventType.Enter) { hovered = true }
            .onPointerEvent(PointerEventType.Exit) { hovered = false }
            .onGloballyPositioned { coords ->
                onScreen = coords.boundsInWindow().bottom > 0f
            },
    ) {
        Crossfade(
            targetState = current,
            animationSpec = tween(700),
            label = "heroCrossfade",
            modifier = Modifier.fillMaxSize(),
        ) { slide ->
            Box(Modifier.fillMaxSize().background(posterBrush(slide))) {
                slide.backdropUrl?.let { url ->
                    AsyncImage(
                        model = url,
                        // Decorative: the title below is the announced text.
                        contentDescription = null,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier.fillMaxSize(),
                    )
                }
            }
        }
        // Left wash for text legibility (mobile hero horizontal gradient).
        Box(
            Modifier.fillMaxSize().background(
                Brush.horizontalGradient(
                    listOf(
                        Color.Black.copy(alpha = 0.72f),
                        Color.Black.copy(alpha = 0.15f),
                        Color.Transparent,
                    ),
                ),
            ),
        )
        // Bottom wash.
        Box(
            Modifier.fillMaxSize().background(
                Brush.verticalGradient(
                    listOf(
                        Color.Transparent,
                        Color.Transparent,
                        Color.Black.copy(alpha = 0.85f),
                    ),
                ),
            ),
        )

        Column(
            Modifier
                .align(Alignment.BottomStart)
                .padding(start = AppSpacing.xl, end = AppSpacing.xl, bottom = 42.dp)
                .fillMaxWidth(0.62f),
        ) {
            Text(
                "FEATURED",
                fontSize = 11.sp,
                letterSpacing = 2.sp,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.primary,
            )
            Spacer(Modifier.height(6.dp))
            Text(
                current.title,
                style = MaterialTheme.typography.headlineMedium,
                fontWeight = FontWeight.Bold,
                color = Color.White,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            Spacer(Modifier.height(8.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (current.rating > 0.0) {
                    Icon(Icons.Default.Star, null, tint = AppColors.ratingGold, modifier = Modifier.size(15.dp))
                    Spacer(Modifier.width(4.dp))
                    Text(
                        "%.1f".format(current.rating),
                        color = Color.White,
                        fontSize = 13.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Spacer(Modifier.width(12.dp))
                }
                if (current.displayYear.isNotBlank()) {
                    Text(current.displayYear, color = Color.White.copy(alpha = 0.8f), fontSize = 13.sp)
                    Spacer(Modifier.width(12.dp))
                }
                // Same badge language as PosterCard (SERIES indigo / MOVIE blue).
                Box(
                    Modifier
                        .background(
                            if (current.mediaType == "tv") AppColors.seriesBadge
                            else AppColors.movieBadge,
                            RoundedCornerShape(4.dp),
                        )
                        .padding(horizontal = 7.dp, vertical = 2.dp),
                ) {
                    Text(
                        if (current.mediaType == "tv") "SERIES" else "MOVIE",
                        color = Color.White,
                        fontSize = 9.sp,
                        fontWeight = FontWeight.Bold,
                    )
                }
            }
            if (current.overview.isNotBlank()) {
                Spacer(Modifier.height(8.dp))
                Text(
                    current.overview,
                    color = Color.White.copy(alpha = 0.7f),
                    fontSize = 13.sp,
                    lineHeight = 18.sp,
                    maxLines = 3,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Spacer(Modifier.height(14.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                val playInteraction = remember { MutableInteractionSource() }
                val playHovered by playInteraction.collectIsHoveredAsState()
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .clip(RoundedCornerShape(8.dp))
                        .background(
                            if (playHovered) MaterialTheme.colorScheme.primary.copy(alpha = 0.88f)
                            else MaterialTheme.colorScheme.primary,
                        )
                        .clickable(interactionSource = playInteraction, indication = null) { onPlay(current) }
                        .appFocusRing(cornerRadius = 8.dp, ringColor = Color.White)
                        .padding(horizontal = 18.dp, vertical = 10.dp),
                ) {
                    Icon(
                        Icons.Default.PlayArrow,
                        contentDescription = null,
                        tint = Color.White,
                        modifier = Modifier.size(20.dp),
                    )
                    Spacer(Modifier.width(4.dp))
                    Text(
                        if (current.mediaType == "tv") "Play S1:E1" else "Play",
                        color = Color.White,
                        fontWeight = FontWeight.Bold,
                        fontSize = 14.sp,
                    )
                }
                val infoInteraction = remember { MutableInteractionSource() }
                val infoHovered by infoInteraction.collectIsHoveredAsState()
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .clip(RoundedCornerShape(8.dp))
                        .background(
                            if (infoHovered) Color.White.copy(alpha = 0.22f)
                            else Color.Black.copy(alpha = 0.45f),
                        )
                        .clickable(interactionSource = infoInteraction, indication = null) { onOpen(current) }
                        .appFocusRing(cornerRadius = 8.dp, ringColor = Color.White)
                        .padding(horizontal = 14.dp, vertical = 10.dp),
                ) {
                    Icon(
                        Icons.Default.Info,
                        contentDescription = null,
                        tint = Color.White,
                        modifier = Modifier.size(18.dp),
                    )
                    Spacer(Modifier.width(6.dp))
                    Text("More info", color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 13.sp)
                }
            }
        }

        // Page indicators (bottom-center, like mobile).
        Row(
            horizontalArrangement = Arrangement.Center,
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .padding(bottom = 14.dp)
                .fillMaxWidth(),
        ) {
            items.forEachIndexed { i, item ->
                val active = i == index
                Box(
                    Modifier
                        .padding(horizontal = 3.dp)
                        .width(if (active) 22.dp else 7.dp)
                        .height(7.dp)
                        .semantics { contentDescription = "Show ${item.title}" }
                        .appClickable(cornerRadius = 4.dp) { index = i }
                        .background(
                            if (active) MaterialTheme.colorScheme.primary
                            else Color.White.copy(alpha = 0.35f),
                            RoundedCornerShape(4.dp),
                        ),
                )
            }
        }
    }
}
