package com.maxstream.app.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.CircularProgressIndicator
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
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
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
import com.maxstream.app.ui.components.HeroCard
import com.maxstream.app.ui.components.PosterCard
import com.maxstream.app.ui.components.RotatingHero
import com.maxstream.app.ui.components.ScrollableColumn
import com.maxstream.app.ui.components.ScrollableGrid
import com.maxstream.app.ui.components.SectionRail
import com.maxstream.app.ui.components.SkeletonBox
import com.maxstream.app.ui.components.SkeletonRail
import com.maxstream.app.ui.theme.AppSpacing
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch

/**
 * Desktop home: hero billboard up top, then named rails (trending, popular,
 * top rated) exactly like the mobile/TV home — and search results in place of
 * the rails while a query is typed. Shows a skeleton while first load runs.
 */
@Composable
fun HomeScreen(
    repository: MediaRepository,
    query: String,
    onOpen: (MediaItem) -> Unit,
    onPlay: (MediaItem) -> Unit,
    onSeeAllMovies: (MovieSection) -> Unit,
    onSeeAllSeries: (SeriesSection) -> Unit,
    syncRevision: Int = 0,
) {
    // Home load with explicit error state + retry — the old produceState let a
    // thrown repository call escape (white screen) or spun forever on failure.
    var homeError by remember { mutableStateOf(false) }
    var homeAttempt by remember { mutableIntStateOf(0) }
    val sections by produceState<List<com.maxstream.app.data.model.HomeSection>>(emptyList(), repository, homeAttempt) {
        value = try {
            homeError = false
            repository.homeSections()
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (t: Throwable) {
            homeError = true
            emptyList()
        }
    }
    var continueError by remember { mutableStateOf(false) }
    var continueAttempt by remember { mutableIntStateOf(0) }
    val continueWatching by produceState<List<com.maxstream.app.data.model.ContinueWatch>>(
        emptyList(),
        repository,
        syncRevision,
        continueAttempt,
    ) {
        value = try {
            continueError = false
            repository.continueWatching()
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (t: Throwable) {
            continueError = true
            emptyList()
        }
    }
    val scope = rememberCoroutineScope()
    var searchPage by remember { mutableIntStateOf(1) }
    var searchHasMore by remember { mutableStateOf(false) }
    var searchLoading by remember { mutableStateOf(false) }
    var searchError by remember { mutableStateOf(false) }
    var searchActiveQuery by remember { mutableStateOf("") }
    var searchAttempt by remember { mutableIntStateOf(0) }
    var searchResults by remember { mutableStateOf<List<MediaItem>>(emptyList()) }
    // Debounced, cancellation-guarded search: LaunchedEffect restarts on every
    // keystroke (delay is interrupted), so only the final query hits the
    // repository; loading flags are keyed to the owning query so a cancelled
    // pass can't clobber the active one's state.
    LaunchedEffect(query, searchAttempt) {
        if (query.isBlank()) {
            searchActiveQuery = ""
            searchPage = 1
            searchHasMore = false
            searchError = false
            searchResults = emptyList()
            searchLoading = false
            return@LaunchedEffect
        }
        delay(300)
        searchLoading = true
        searchActiveQuery = query
        searchPage = 1
        searchError = false
        searchResults = emptyList()
        try {
            val results = repository.search(query, 1)
            searchResults = results
            searchHasMore = results.isNotEmpty()
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (t: Throwable) {
            searchError = true
            searchHasMore = false
        } finally {
            if (searchActiveQuery == query) searchLoading = false
        }
    }
    val searchQuery = query
    val searchLoadMore: (() -> Unit)? =
        if (searchHasMore && !searchLoading && searchQuery.isNotBlank() && !searchError) {
            {
                if (!searchLoading) {
                    searchLoading = true
                    scope.launch {
                        val nextPage = searchPage + 1
                        try {
                            val next = repository.search(searchQuery, nextPage)
                            if (searchQuery != searchActiveQuery) return@launch
                            searchPage = nextPage
                            searchResults = (searchResults + next).distinctBy { "${it.mediaType}:${it.id}" }
                            if (next.isEmpty()) searchHasMore = false
                        } catch (e: kotlinx.coroutines.CancellationException) {
                            throw e
                        } catch (t: Throwable) {
                            if (searchQuery == searchActiveQuery) searchHasMore = false
                        } finally {
                            if (searchQuery == searchActiveQuery) searchLoading = false
                        }
                    }
                }
            }
        } else null

    if (query.isNotBlank()) {
        Column(Modifier.fillMaxSize().padding(AppSpacing.gutter)) {
            Text(
                when {
                    searchError -> "Search failed"
                    searchLoading && searchResults.isEmpty() -> "Searching \u201C$query\u201D\u2026"
                    searchResults.isEmpty() -> "No results for \u201C$query\u201D"
                    else -> "Results for \u201C$query\u201D (${searchResults.size})"
                },
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.padding(bottom = 12.dp),
            )
            when {
                searchError -> ErrorState(
                    title = "Couldn\u2019t search",
                    message = "The catalog request failed. Check your connection and try again.",
                    onRetry = { searchAttempt++ },
                )
                searchResults.isEmpty() && !searchLoading -> EmptyState(
                    title = "No matches",
                    message = "Try a different title, genre, or year.",
                    icon = Icons.Default.Search,
                )
                else -> MediaBrowserGrid(searchResults, onOpen = onOpen, onLoadMore = searchLoadMore, loading = searchLoading)
            }
        }
        return
    }

    val loadingHome = sections.isEmpty() && !homeError
    val hero = sections.firstOrNull()?.items?.firstOrNull()

    ScrollableColumn {
        if (homeError && sections.isEmpty()) {
            Spacer(Modifier.height(AppSpacing.xl))
            ErrorState(
                title = "Couldn\u2019t load home",
                message = "The catalog request failed. Check your connection and try again.",
                onRetry = { homeAttempt++ },
            )
            return@ScrollableColumn
        }
        if (loadingHome) {
            Spacer(Modifier.height(AppSpacing.gutter))
            // Skeleton mirrors the real RotatingHero (340dp) so content
            // doesn't jump when it lands.
            SkeletonBox(width = 400.dp, height = 340.dp, modifier = Modifier.padding(horizontal = AppSpacing.gutter))
            Spacer(Modifier.height(AppSpacing.xl))
            SkeletonRail(modifier = Modifier.padding(horizontal = AppSpacing.gutter))
            Spacer(Modifier.height(AppSpacing.gutter))
            SkeletonRail(modifier = Modifier.padding(horizontal = AppSpacing.gutter))
            return@ScrollableColumn
        }

        // Rotating full-bleed hero from trending movies + series (mobile parity).
        val featured = remember(sections) {
            (sections.firstOrNull { it.title.contains("Trending movies", true) }?.items.orEmpty() +
                sections.firstOrNull { it.title.contains("Trending series", true) }?.items.orEmpty())
                .filter { it.backdropUrl != null }
                .take(5)
        }
        if (featured.isNotEmpty()) {
            RotatingHero(
                items = featured,
                onPlay = onPlay,
                onOpen = onOpen,
            )
            Spacer(Modifier.height(18.dp))
        } else if (hero != null) {
            Spacer(Modifier.height(14.dp))
            HeroCard(
                item = hero,
                onPlay = { onPlay(hero) },
                onOpen = { onOpen(hero) },
            )
            Spacer(Modifier.height(18.dp))
        }

        if (continueWatching.isNotEmpty()) {
            val cwItems = continueWatching.map { c -> c.item.copy(progress = c.progress) }
            val cwKeys = continueWatching.map { c ->
                "${c.item.mediaType}:${c.item.id}:s${c.season}:e${c.episode}"
            }
            SectionRail(
                title = "Continue watching",
                items = cwItems,
                itemKeys = cwKeys,
                onOpen = { item ->
                    val idx = cwItems.indexOfFirst { it === item }
                    val match = continueWatching.getOrNull(idx)
                    if (match != null) onOpen(match.item.copy(progress = match.progress)) else onOpen(item)
                },
                showProgress = true,
            )
            Spacer(Modifier.height(6.dp))
        }

        sections.forEach { section ->
            val seeAllMovies = when (section.title) {
                "Trending movies" -> MovieSection.POPULAR
                "Popular movies" -> MovieSection.POPULAR
                "Top rated" -> MovieSection.TOP_RATED
                else -> null
            }
            val seeAllSeries = when (section.title) {
                "Trending series" -> SeriesSection.POPULAR
                "Popular series" -> SeriesSection.POPULAR
                else -> null
            }
            SectionRail(
                title = section.title,
                items = section.items,
                onOpen = onOpen,
                onSeeAll = when {
                    seeAllMovies != null -> { { onSeeAllMovies(seeAllMovies) } }
                    seeAllSeries != null -> { { onSeeAllSeries(seeAllSeries) } }
                    else -> null
                },
            )
        }
        Spacer(Modifier.height(16.dp))
    }
}

/** Shared poster grid used by search + catalog screens — scrolls with the
 *  right-edge scrollbar and keyboard keys. When [onLoadMore] is set the grid
 *  keeps paging as you approach the bottom (infinite scroll). */
@Composable
fun MediaBrowserGrid(
    items: List<MediaItem>,
    onOpen: (MediaItem) -> Unit,
    onLoadMore: (() -> Unit)? = null,
    loading: Boolean = false,
) {
    if (items.isEmpty() && !loading) return
    val gridState = rememberLazyGridState()
    if (onLoadMore != null) {
        // Gate on `loading` + the *current* onLoadMore (rememberUpdatedState):
        // the old version keyed only on (gridState, items) and called
        // onLoadMore on every layout emission near the bottom, re-firing while
        // a request was already in flight and spinning the loop forever.
        val latestOnLoadMore by rememberUpdatedState(onLoadMore)
        LaunchedEffect(gridState, items, loading) {
            if (loading) return@LaunchedEffect
            snapshotFlow {
                val layout = gridState.layoutInfo
                val last = layout.visibleItemsInfo.lastOrNull()?.index ?: -1
                last to layout.totalItemsCount
            }.collect { (last, total) ->
                if (!loading && total > 0 && last >= total - 6) latestOnLoadMore()
            }
        }
    }
    val uniqueItems = remember(items) { items.distinctBy { "${it.mediaType}:${it.id}" } }
    ScrollableGrid(state = gridState) {
        LazyVerticalGrid(
            state = gridState,
            columns = GridCells.Adaptive(148.dp),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = 24.dp),
            horizontalArrangement = Arrangement.spacedBy(14.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
            modifier = Modifier.fillMaxSize(),
        ) {
            items(uniqueItems, key = { "${it.mediaType}:${it.id}" }) { item ->
                PosterCard(item, width = 148.dp, onClick = { onOpen(item) })
            }
            if (loading) {
                item(key = "loading", span = { GridItemSpan(maxLineSpan) }) {
                    Box(
                        Modifier.fillMaxWidth().padding(18.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        CircularProgressIndicator(Modifier.size(22.dp), strokeWidth = 2.dp)
                    }
                }
            }
        }
    }
}

