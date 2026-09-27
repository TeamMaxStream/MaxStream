package com.maxstream.app.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * Shared empty state used by Watchlist, search, Home, and catalog screens so
 * every "nothing here" surface looks the same. Uses fillMaxWidth + a min
 * height instead of fillMaxSize so it can't overflow a Column that already
 * has a header (the old fillMaxSize measured against the full parent height).
 */
@Composable
fun EmptyState(
    title: String,
    message: String,
    modifier: Modifier = Modifier,
    icon: ImageVector? = null,
) {
    Box(
        modifier.fillMaxWidth().heightIn(min = 260.dp),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier.widthIn(max = 420.dp).padding(24.dp),
        ) {
            if (icon != null) {
                Icon(
                    icon,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.outline,
                    modifier = Modifier.size(48.dp),
                )
                Spacer(Modifier.height(14.dp))
            }
            Text(
                title,
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onSurface,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(8.dp))
            Text(
                message,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
        }
    }
}

/**
 * Error state with a retry action — the app previously had *no* error UI
 * anywhere (failures silently fell back to sample data or a dead spinner).
 */
@Composable
fun ErrorState(
    title: String,
    message: String,
    modifier: Modifier = Modifier,
    onRetry: (() -> Unit)? = null,
    retryLabel: String = "Try again",
) {
    Box(
        modifier
            .fillMaxWidth()
            .heightIn(min = 260.dp)
            .semantics { liveRegion = LiveRegionMode.Polite },
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier.widthIn(max = 420.dp).padding(24.dp),
        ) {
            Text(
                title,
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onSurface,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(8.dp))
            Text(
                message,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
            if (onRetry != null) {
                Spacer(Modifier.height(16.dp))
                Button(onClick = onRetry) {
                    Icon(Icons.Default.Refresh, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(retryLabel)
                }
            }
        }
    }
}

/** Pulsing placeholder block for Home / grid skeletons. */
@Composable
fun SkeletonBox(
    width: Dp,
    height: Dp,
    modifier: Modifier = Modifier,
) {
    val alpha = pulseAlpha()
    Box(
        modifier
            .width(width)
            .height(height)
            .background(
                MaterialTheme.colorScheme.surfaceVariant.copy(alpha = alpha),
                MaterialTheme.shapes.small,
            ),
    )
}

/** Full-width skeleton rail used while Home sections load. */
@Composable
fun SkeletonRail(modifier: Modifier = Modifier) {
    Column(modifier) {
        SkeletonBox(width = 160.dp, height = 18.dp)
        Spacer(Modifier.height(12.dp))
        androidx.compose.foundation.layout.Row(
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            // 132x220 + text block ≈ a real poster card (was 196 → layout jump).
            repeat(6) {
                SkeletonBox(width = 132.dp, height = 220.dp)
            }
        }
    }
}
