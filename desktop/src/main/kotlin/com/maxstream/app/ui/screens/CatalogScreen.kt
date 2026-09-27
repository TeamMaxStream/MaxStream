package com.maxstream.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bookmark
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.maxstream.app.data.model.MediaItem
import com.maxstream.app.data.repository.MediaRepository
import com.maxstream.app.data.repository.MovieSection
import com.maxstream.app.data.repository.SeriesSection
import com.maxstream.app.ui.components.EmptyState
import com.maxstream.app.ui.components.ErrorState
import com.maxstream.app.ui.components.appClickable
import com.maxstream.app.ui.theme.AppSpacing
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

/**
 * Movies screen with section tabs (Popular / Top rated / Upcoming) matching the
 * mobile/TV build — a tabbed browse grid instead of a flat "all movies" list.
 */
@Composable
fun MoviesScreen(
    repository: MediaRepository,
    initialSection: MovieSection = MovieSection.POPULAR,
    onOpen: (MediaItem) -> Unit,
) {
    SectionScreen(
        title = "Movies",
        subtitleProvider = { "Browse the TMDB catalog" },
        tabs = MovieSection.entries.map { TabSpec(it.display, it.name) },
        initialTab = initialSection.name,
        load = { tabName, page ->
            val section = MovieSection.entries.find { it.name == tabName } ?: MovieSection.POPULAR
            repository.movies(section, page)
        },
        onOpen = onOpen,
    )
}

@Composable
fun SeriesScreen(
    repository: MediaRepository,
    initialSection: SeriesSection = SeriesSection.POPULAR,
    onOpen: (MediaItem) -> Unit,
) {
    SectionScreen(
        title = "Series",
        subtitleProvider = { "Browse the series catalog" },
        tabs = SeriesSection.entries.map { TabSpec(it.display, it.name) },
        initialTab = initialSection.name,
        load = { tabName, page ->
            val section = SeriesSection.entries.find { it.name == tabName } ?: SeriesSection.POPULAR
            repository.series(section, page)
        },
        onOpen = onOpen,
    )
}

/** Watchlist backed by Firebase cloud sync (signed out: explains + empty). */
@Composable
fun WatchlistScreen(
    repository: MediaRepository,
    isSignedIn: Boolean,
    onOpen: (MediaItem) -> Unit,
    syncRevision: Int = 0,
) {
    // Loading + error were invisible before: while `watchlist()` ran the UI
    // showed the "nothing saved yet" empty state.
    var wlLoading by remember { mutableStateOf(true) }
    var wlError by remember { mutableStateOf(false) }
    var wlAttempt by remember { mutableIntStateOf(0) }
    val items by produceState<List<MediaItem>>(emptyList(), repository, isSignedIn, syncRevision, wlAttempt) {
        wlLoading = true
        wlError = false
        value = try {
            repository.watchlist().also { wlLoading = false }
        } catch (e: CancellationException) {
            // Leave wlLoading alone — a newer attempt owns the flag.
            throw e
        } catch (t: Throwable) {
            wlError = true
            wlLoading = false
            emptyList()
        }
    }

    Column(Modifier.fillMaxSize().padding(AppSpacing.gutter)) {
        Text(
            "Watchlist",
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Text(
            if (isSignedIn) "Synced to your account" else "Sign in to sync your watchlist across devices",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(AppSpacing.lg))

        when {
            wlError -> ErrorState(
                title = "Couldn\u2019t load watchlist",
                message = "The sync request failed. Check your connection and try again.",
                onRetry = { wlAttempt++ },
            )
            wlLoading -> MediaBrowserGrid(emptyList(), onOpen = onOpen, loading = true)
            items.isEmpty() -> EmptyState(
                title = if (isSignedIn) "Nothing on your watchlist yet." else "Sign in to start your watchlist",
                message = if (isSignedIn)
                    "Titles you save here are available on the phone and TV app too."
                else
                    "Sign in with your email, then add titles from any details page.",
                icon = Icons.Default.Bookmark,
            )
            else -> MediaBrowserGrid(items, onOpen = onOpen)
        }
    }
}

private data class TabSpec(val display: String, val key: String)

@Composable
private fun SectionScreen(
    title: String,
    subtitleProvider: (String) -> String,
    tabs: List<TabSpec>,
    initialTab: String,
    load: suspend (tabName: String, page: Int) -> List<MediaItem>,
    onOpen: (MediaItem) -> Unit,
) {
    var selectedTab by remember { mutableIntStateOf(tabs.indexOfFirst { it.key == initialTab }.coerceAtLeast(0)) }
    val scope = rememberCoroutineScope()
    var page by remember { mutableIntStateOf(1) }
    var hasMore by remember { mutableStateOf(true) }
    var loading by remember { mutableStateOf(false) }
    var loadError by remember { mutableStateOf(false) }
    var attempt by remember { mutableIntStateOf(0) }
    var activeKey by remember { mutableStateOf("") }
    var items by remember { mutableStateOf<List<MediaItem>>(emptyList()) }

    LaunchedEffect(selectedTab, tabs, attempt) {
        val key = tabs.getOrNull(selectedTab)?.key ?: tabs.first().key
        page = 1
        hasMore = true
        activeKey = key
        // Drop the previous tab's items immediately — keeping them meant the
        // grid showed the old tab's titles under a spinner during the fetch.
        items = emptyList()
        loading = true
        loadError = false
        try {
            val first = load(key, 1)
            items = first
            hasMore = first.isNotEmpty()
        } catch (e: CancellationException) {
            throw e
        } catch (t: Throwable) {
            loadError = true
            hasMore = false
        } finally {
            if (activeKey == key) loading = false
        }
    }

    val loadMore: (() -> Unit)? =
        if (hasMore && !loading && !loadError) {
            {
                if (!loading) {
                    loading = true
                    scope.launch {
                        val key = tabs.getOrNull(selectedTab)?.key ?: tabs.first().key
                        if (key != activeKey) return@launch
                        val nextPage = page + 1
                        try {
                            val next = load(key, nextPage)
                            if (key != activeKey) return@launch
                            page = nextPage
                            items = (items + next).distinctBy { "${it.mediaType}:${it.id}" }
                            if (next.isEmpty()) hasMore = false
                        } catch (e: CancellationException) {
                            throw e
                        } catch (t: Throwable) {
                            if (key == activeKey) hasMore = false
                        } finally {
                            if (key == activeKey) loading = false
                        }
                    }
                }
            }
        } else null

    Column(Modifier.fillMaxSize().padding(AppSpacing.gutter)) {
        Text(
            title,
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Text(
            subtitleProvider(tabs.getOrNull(selectedTab)?.display ?: ""),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        Spacer(Modifier.height(AppSpacing.md))

        Row(
            horizontalArrangement = Arrangement.spacedBy(AppSpacing.sm),
            modifier = Modifier.horizontalScroll(rememberScrollState()),
        ) {
            tabs.forEachIndexed { index, tab ->
                val selectedItem = index == selectedTab
                Box(
                    Modifier
                        .appClickable(cornerRadius = 20.dp) { selectedTab = index }
                        .background(
                            if (selectedItem) MaterialTheme.colorScheme.primary
                            else MaterialTheme.colorScheme.surfaceVariant,
                            RoundedCornerShape(20.dp),
                        )
                        .padding(horizontal = 16.dp, vertical = 7.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        tab.display,
                        color = if (selectedItem) MaterialTheme.colorScheme.onPrimary
                                else MaterialTheme.colorScheme.onSurface,
                        fontWeight = if (selectedItem) FontWeight.SemiBold else FontWeight.Normal,
                        fontSize = 13.sp,
                    )
                }
            }
        }

        Spacer(Modifier.height(AppSpacing.lg))

        when {
            loadError && items.isEmpty() -> ErrorState(
                title = "Couldn\u2019t load $title",
                message = "The catalog request failed. Check your connection and try again.",
                onRetry = { attempt++ },
            )
            else -> MediaBrowserGrid(items, onOpen = onOpen, onLoadMore = loadMore, loading = loading)
        }
    }
}